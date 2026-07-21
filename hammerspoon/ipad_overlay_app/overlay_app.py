#!/usr/bin/env python3
"""iPad control overlay: frosted NSPanel with keyboard-style buttons.

Driven by Hammerspoon over a unix control socket (show / hide / quit /
status); stdin is unusable because hs.task delivers EOF immediately. An
orphan watchdog exits when the parent (Hammerspoon) dies. Plain keys post
CGEvents directly; copy/paste/voice/transform round-trip through Hammerspoon
so the terminal-aware SendActions/GptVoice logic stays the single owner of
that behavior.

All button visuals live on hosted CALayers (never on NSView backing layers:
mutating those crashes AppKit's display-link flush with SIGTRAP).
"""

import argparse
import functools
import json
import os
import queue
import signal
import subprocess
import shutil
import socket
import sys
import threading
import time
from pathlib import Path

import objc
from Cocoa import (
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSApplicationDidChangeScreenParametersNotification,
    NSNotificationCenter,
    NSBezierPath,
    NSEdgeInsetsMake,
    NSImageResizingModeStretch,
    NSBitmapImageRep,
    NSColor,
    NSCompositingOperationSourceOver,
    NSDeviceRGBColorSpace,
    NSGraphicsContext,
    NSZeroRect,
    NSDistributedNotificationCenter,
    NSFloatingWindowLevel,
    NSFontWeightMedium,
    NSImage,
    NSImageSymbolConfiguration,
    NSMakeRect,
    NSObject,
    NSPanel,
    NSRunLoop,
    NSRunningApplication,
    NSScreen,
    NSTimer,
    NSView,
    NSVisualEffectBlendingModeBehindWindow,
    NSVisualEffectMaterialPopover,
    NSVisualEffectStateActive,
    NSVisualEffectView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
    NSAnimationContext,
)
from Quartz import (
    CALayer,
    CABasicAnimation,
    CAMediaTimingFunction,
    CATransaction,
    CGDisplayBounds,
    CGEventCreateKeyboardEvent,
    CGEventPost,
    CGGetActiveDisplayList,
    CGMainDisplayID,
    kCGHIDEventTap,
)
from PyObjCTools import AppHelper

BUTTON = 40
ARROW_H = 19
ARROW_HGAP = 4
ARROW_VGAP = 2
GAP = 8
GROUP_GAP = 20
PAD = 12
RADIUS_PANEL = 20.0
RADIUS_BTN = 10.0

KEYCODES = {
    "esc": 53,
    "return": 36,
    "delete": 51,
    "left": 123,
    "right": 124,
    "down": 125,
    "up": 126,
}

STATE_DIR = Path.home() / ".local" / "state" / "ipad-overlay"
STATE_FILE = STATE_DIR / "state.json"
LOG_FILE = STATE_DIR / "overlay.log"
CONTROL_SOCK = Path.home() / ".transcriptions-gpt" / "control.sock"
OWN_SOCK = STATE_DIR / "control.sock"

KB_BUNDLE_ID = "com.apple.inputmethod.AssistiveControl"


# Live display bounds from the window server, in Cocoa (bottom-left origin)
# coordinates. NSScreen's list goes stale in this background app when the
# physical monitor and the BetterDisplay virtual display swap (Jump/Sidecar
# transitions), which left the panel clamped to a screen that no longer
# exists.
def display_frames():
    err, ids, _cnt = CGGetActiveDisplayList(16, None, None)
    if err or not ids:
        return [s.visibleFrame() for s in NSScreen.screens()]
    main_h = CGDisplayBounds(CGMainDisplayID()).size.height
    frames = []
    for did in ids:
        b = CGDisplayBounds(did)
        frame = NSMakeRect(
            b.origin.x, main_h - (b.origin.y + b.size.height),
            b.size.width, b.size.height)
        # Prefer the matching NSScreen's visibleFrame (menubar/Dock carved
        # out); fall back to raw bounds when the NSScreen list is stale.
        for s in NSScreen.screens():
            sf = s.frame()
            if abs(sf.origin.x - frame.origin.x) < 1 \
                    and abs(sf.origin.y - frame.origin.y) < 1 \
                    and abs(sf.size.width - frame.size.width) < 1:
                frame = s.visibleFrame()
                break
        frames.append(frame)
    return frames


# Launch-services query, deliberately not pgrep: no per-second subprocess
# forks from inside a Cocoa app. LS keeps dead entries around for seconds,
# so confirm each pid is actually alive.
def kb_running():
    for app in NSRunningApplication.runningApplicationsWithBundleIdentifier_(KB_BUNDLE_ID) or []:
        try:
            os.kill(app.processIdentifier(), 0)
            return True
        except OSError:
            pass
    return False


def log(msg):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except OSError:
        pass


# Every ObjC→Python entry point must be wrapped: an exception escaping into
# AppKit silently kills AppHelper's callAfter machinery for the rest of the
# process (all UI updates freeze, quit ignored) — happened twice live.
def safe(fn):
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except Exception as exc:
            log("%s failed: %r" % (fn.__name__, exc))
    return wrapper


# Main-thread dispatch through a plain queue drained by an NSTimer: work is
# never pushed at the runloop from background threads, and one failing action
# can't break delivery of the rest.
MAIN_QUEUE = queue.Queue()


def on_main(fn, *args):
    MAIN_QUEUE.put((fn, args))


def drain_main_queue():
    while True:
        try:
            fn, args = MAIN_QUEUE.get_nowait()
        except queue.Empty:
            return
        try:
            fn(*args)
        except Exception as exc:
            log("main-thread action failed: %r" % exc)


def on_main_later(delay, fn):
    timer = threading.Timer(delay, lambda: on_main(fn))
    timer.daemon = True
    timer.start()


def is_dark():
    app = NSApplication.sharedApplication()
    name = app.effectiveAppearance().bestMatchFromAppearancesWithNames_(
        ["NSAppearanceNameAqua", "NSAppearanceNameDarkAqua"]
    )
    return name == "NSAppearanceNameDarkAqua"


TINTS = {
    None: NSColor.labelColor,
    "red": NSColor.systemRedColor,
    "accent": NSColor.controlAccentColor,
    "secondary": NSColor.secondaryLabelColor,
    "disabled": NSColor.tertiaryLabelColor,
}


def symbol_cgimage(name, point_size, tint_key, appearance, scale=2.0):
    """Rasterize a tinted SF Symbol to a CGImage (colors baked per theme)."""
    img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
    if img is None:
        return None, (0, 0)
    size_cfg = NSImageSymbolConfiguration.configurationWithPointSize_weight_(
        point_size, NSFontWeightMedium
    )
    result = {}

    def render():
        color = TINTS.get(tint_key, NSColor.labelColor)()
        color_cfg = NSImageSymbolConfiguration.configurationWithHierarchicalColor_(color)
        tinted = img.imageWithSymbolConfiguration_(
            size_cfg.configurationByApplyingConfiguration_(color_cfg)
        )
        w, h = tinted.size().width, tinted.size().height
        rep = NSBitmapImageRep.alloc() \
            .initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
                None, int(w * scale), int(h * scale), 8, 4, True, False,
                NSDeviceRGBColorSpace, 0, 0)
        rep.setSize_((w, h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.setCurrentContext_(
            NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))
        tinted.drawInRect_fromRect_operation_fraction_(
            NSMakeRect(0, 0, w, h), NSZeroRect,
            NSCompositingOperationSourceOver, 1.0)
        NSGraphicsContext.restoreGraphicsState()
        result["cg"] = rep.CGImage()
        result["size"] = (w, h)

    # performAsCurrentDrawingAppearance resolves dynamic colors for the
    # panel's theme, not the process default.
    appearance.performAsCurrentDrawingAppearance_(render)
    return result.get("cg"), result.get("size", (0, 0))


class KeyButton(NSView):
    """One key: hosted layers for fill/icon, press fill/dim + pulse."""

    @objc.python_method
    def setup(self, symbol, point_size, callback, app):
        self._symbol = symbol
        self._point_size = point_size
        self._callback = callback
        self._app = app
        self._btn_enabled = True
        self._pressed = False
        self._tint_key = None
        self._pulsing = False

        self.setWantsLayer_(True)
        w, h = self.frame().size.width, self.frame().size.height

        scale = CALayer.layer()
        scale.setFrame_(NSMakeRect(0, 0, w, h))
        scale.setAnchorPoint_((0.5, 0.5))
        scale.setPosition_((w / 2.0, h / 2.0))
        self.layer().addSublayer_(scale)
        self._scale_layer = scale

        bg = CALayer.layer()
        bg.setFrame_(NSMakeRect(0, 0, w, h))
        bg.setCornerRadius_(RADIUS_BTN)
        try:
            bg.setCornerCurve_("continuous")
        except Exception:
            pass
        scale.addSublayer_(bg)
        self._bg = bg

        icon = CALayer.layer()
        icon.setFrame_(NSMakeRect(0, 0, w, h))
        icon.setContentsGravity_("center")
        scale.addSublayer_(icon)
        self._icon = icon
        self.render_icon()
        self._refresh_fill(0.01)
        return self

    @objc.python_method
    def render_icon(self):
        tint = "disabled" if not self._btn_enabled else self._tint_key
        # Raster scale must match the layer's contentsScale, or icons draw at
        # the wrong point size on screens whose backing factor differs (1x
        # external monitor vs 2x Sidecar).
        backing = self._app.panel.backingScaleFactor() or 2.0
        cg, _size = symbol_cgimage(
            self._symbol, self._point_size, tint,
            self._app.panel.effectiveAppearance(), scale=backing,
        )
        if cg is None:
            log("render_icon %s tint=%r: rasterization returned None"
                % (self._symbol, tint))
            return
        self._icon.setContentsScale_(backing)
        self._icon.setContents_(cg)

    def mouseDownCanMoveWindow(self):
        # Disabled keys act as panel background so dragging over them works.
        return not self._btn_enabled

    @objc.python_method
    def _fill_color(self):
        dark = is_dark()
        base = NSColor.whiteColor() if dark else NSColor.blackColor()
        if self._pressed:
            return base.colorWithAlphaComponent_(0.34 if dark else 0.25)
        # Resting key fill: touch/pencil input has no hover (a Pencil tap
        # would leave a "hover" stuck on the key until the next tap), so
        # keys must read as keys without it and there is no hover state.
        return base.colorWithAlphaComponent_(0.055 if dark else 0.04)

    @objc.python_method
    def _refresh_fill(self, duration=0.12):
        new_color = self._fill_color().CGColor()
        anim = CABasicAnimation.animationWithKeyPath_("backgroundColor")
        anim.setFromValue_(self._bg.backgroundColor())
        anim.setToValue_(new_color)
        anim.setDuration_(duration)
        self._bg.addAnimation_forKey_(anim, "fill")
        CATransaction.begin()
        CATransaction.setDisableActions_(True)
        self._bg.setBackgroundColor_(new_color)
        CATransaction.commit()

    # No layer-transform animations here: animating `transform` on a button
    # layer while a mouseDragged arrives mid-press (every Pencil tap drifts a
    # pixel) permanently freezes this window's compositing on macOS 27 —
    # visuals stop updating process-wide while everything else keeps running.
    # Press feedback = fill darkening + icon dim, both proven safe.
    @objc.python_method
    def _press_icon(self, down):
        if self._pulsing:
            return
        target = 0.55 if down else 1.0
        anim = CABasicAnimation.animationWithKeyPath_("opacity")
        anim.setToValue_(target)
        anim.setDuration_(0.08 if down else 0.3)
        self._icon.addAnimation_forKey_(anim, "press")
        CATransaction.begin()
        CATransaction.setDisableActions_(True)
        self._icon.setOpacity_(target)
        CATransaction.commit()

    def mouseDown_(self, event):
        safe(self._mouse_down)(event)

    def acceptsFirstMouse_(self, event):
        return True

    def mouseDragged_(self, event):
        # Swallow press-drift: bubbling it up would reach the panel's default
        # window-move handling (see setMovableByWindowBackground note).
        pass

    def mouseUp_(self, event):
        safe(self._mouse_up)(event)

    @objc.python_method
    def _mouse_down(self, event):
        if not self._btn_enabled:
            self.window().performWindowDragWithEvent_(event)
            return
        self._pressed = True
        self._refresh_fill(0.06)
        self._press_icon(True)

    @objc.python_method
    def _mouse_up(self, event):
        if not self._pressed:
            return
        self._pressed = False
        # Slow fade back so even an instantaneous tap leaves a visible
        # afterglow — a quick tap otherwise shows nothing.
        self._refresh_fill(0.45)
        self._press_icon(False)
        point = self.convertPoint_fromView_(event.locationInWindow(), None)
        b = self.bounds()
        if 0 <= point.x <= b.size.width and 0 <= point.y <= b.size.height \
                and self._callback:
            try:
                self._callback()
            except Exception as exc:
                log("action %s failed: %r" % (self._symbol, exc))

    @objc.python_method
    def set_button_enabled(self, value):
        value = bool(value)
        if value == self._btn_enabled:
            return
        self._btn_enabled = value
        if not value:
            self._pressed = False
            self._refresh_fill()
        self.render_icon()

    @objc.python_method
    def set_tint(self, tint_key):
        if tint_key == self._tint_key:
            return
        self._tint_key = tint_key
        self.render_icon()

    @objc.python_method
    def set_pulsing(self, value):
        value = bool(value)
        if value == self._pulsing:
            return
        self._pulsing = value
        if value:
            anim = CABasicAnimation.animationWithKeyPath_("opacity")
            anim.setFromValue_(1.0)
            anim.setToValue_(0.55)
            anim.setDuration_(0.55)
            anim.setAutoreverses_(True)
            anim.setRepeatCount_(1e9)
            self._icon.addAnimation_forKey_(anim, "pulse")
        else:
            self._icon.removeAnimationForKey_("pulse")
            self._icon.setOpacity_(1.0)


class DragRootView(NSVisualEffectView):
    # isMovableByWindowBackground is unreliable for borderless nonactivating
    # panels; drive the drag explicitly.
    def mouseDown_(self, event):
        safe(self.window().performWindowDragWithEvent_)(event)


class OverlayDelegate(NSObject):
    def initWithApp_(self, app):
        self = objc.super(OverlayDelegate, self).init()
        self._app = app
        return self

    def windowDidMove_(self, notification):
        safe(self._app.schedule_frame_save)()

    def themeChanged_(self, notification):
        on_main(self._app.apply_theme)

    def screensChanged_(self, notification):
        on_main(self._app.reclamp_to_screens)

    def windowDidChangeBackingProperties_(self, notification):
        on_main(self._app.rerender_icons)

    def drainTick_(self, timer):
        drain_main_queue()
        # Layer mutations from timer context don't always reach the screen on
        # their own (stale icons observed after window drags) — flush.
        CATransaction.flush()

    def kbTick_(self, timer):
        safe(self._app.tick_kb)()


class OverlayApp:
    def __init__(self):
        self.ns_app = NSApplication.sharedApplication()
        self.ns_app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        self.panel = None
        self.root = None
        self.buttons = {}
        self.visible = False
        self.voice_state = "offline"
        self._optimistic_until = 0.0
        self._kb_optimistic_until = 0.0
        self._kb_expected = False
        self._save_due = None
        self._animating = False
        self._target_frame = None
        self.hs_binary = self._resolve_hs()
        self._build_panel()
        self.delegate = OverlayDelegate.alloc().initWithApp_(self)
        self.panel.setDelegate_(self.delegate)
        NSDistributedNotificationCenter.defaultCenter() \
            .addObserver_selector_name_object_(
                self.delegate, b"themeChanged:",
                "AppleInterfaceThemeChangedNotification", None)
        NSNotificationCenter.defaultCenter() \
            .addObserver_selector_name_object_(
                self.delegate, b"screensChanged:",
                NSApplicationDidChangeScreenParametersNotification, None)
        run_loop = NSRunLoop.currentRunLoop()
        self._drain_timer = NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats_(
            0.1, self.delegate, b"drainTick:", None, True)
        run_loop.addTimer_forMode_(self._drain_timer, "kCFRunLoopCommonModes")
        self._kb_timer = NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self.delegate, b"kbTick:", None, True)
        run_loop.addTimer_forMode_(self._kb_timer, "kCFRunLoopCommonModes")

    @staticmethod
    def _resolve_hs():
        for candidate in (shutil.which("hs"), "/opt/homebrew/bin/hs", "/usr/local/bin/hs"):
            if candidate and os.path.exists(candidate):
                return candidate
        log("hs binary not found; copy/paste/voice buttons inert")
        return None

    # -- layout ---------------------------------------------------------

    def _layout(self):
        groups = [
            [("esc", "escape", 15, lambda: self._send_key("esc"))],
            [
                ("copy", "doc.on.doc", 15, lambda: self._send_hs("_G.SendActions.sendCopy()")),
                ("paste", "doc.on.clipboard", 15, lambda: self._send_hs("_G.SendActions.sendPaste()")),
            ],
            [
                ("mic", "mic", 16, self._on_mic),
                ("wand", "wand.and.stars", 15, self._on_wand),
                ("keyboard", "keyboard", 15, self._on_keyboard),
            ],
            [
                ("delete", "delete.left", 15, lambda: self._send_key("delete")),
                ("return", "return", 15, lambda: self._send_key("return")),
            ],
        ]

        specs = []
        x = PAD
        for group in groups:
            for i, (name, sym, size, cb) in enumerate(group):
                specs.append((name, sym, size, cb, NSMakeRect(x, PAD, BUTTON, BUTTON)))
                x += BUTTON + (GAP if i < len(group) - 1 else 0)
            x += GROUP_GAP

        cluster_x = x
        col = lambda i: cluster_x + i * (BUTTON + ARROW_HGAP)
        top_y = PAD + ARROW_H + ARROW_VGAP
        specs.extend([
            ("up", "arrow.up", 11, lambda: self._send_key("up"),
             NSMakeRect(col(1), top_y, BUTTON, ARROW_H)),
            ("left", "arrow.left", 11, lambda: self._send_key("left"),
             NSMakeRect(col(0), PAD, BUTTON, ARROW_H)),
            ("down", "arrow.down", 11, lambda: self._send_key("down"),
             NSMakeRect(col(1), PAD, BUTTON, ARROW_H)),
            ("right", "arrow.right", 11, lambda: self._send_key("right"),
             NSMakeRect(col(2), PAD, BUTTON, ARROW_H)),
        ])

        width = col(2) + BUTTON + PAD
        height = BUTTON + 2 * PAD
        return specs, width, height

    @staticmethod
    def _rounded_mask(radius):
        size = 2.0 * radius + 1.0

        def draw(rect):
            NSColor.blackColor().set()
            NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                rect, radius, radius).fill()
            return True

        img = NSImage.imageWithSize_flipped_drawingHandler_(
            (size, size), False, draw)
        img.setCapInsets_(NSEdgeInsetsMake(radius, radius, radius, radius))
        img.setResizingMode_(NSImageResizingModeStretch)
        return img

    def _build_panel(self):
        specs, width, height = self._layout()
        frame = self._restore_frame(width, height)
        self._target_frame = frame

        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            frame,
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            2,  # NSBackingStoreBuffered
            False,
        )
        panel.setLevel_(NSFloatingWindowLevel)
        panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
        )
        panel.setHasShadow_(True)
        panel.setOpaque_(False)
        panel.setBackgroundColor_(NSColor.clearColor())
        # Never let AppKit start a background-move session on its own: a
        # mouseDragged bubbling up mid-press (every Pencil tap has micro
        # movement) wedges the window server into showing stale frames for
        # this window forever. Drags are driven explicitly via
        # performWindowDragWithEvent instead.
        panel.setMovableByWindowBackground_(False)
        panel.setBecomesKeyOnlyIfNeeded_(True)
        panel.setHidesOnDeactivate_(False)
        self.panel = panel

        root = DragRootView.alloc().initWithFrame_(NSMakeRect(0, 0, width, height))
        root.setBlendingMode_(NSVisualEffectBlendingModeBehindWindow)
        root.setState_(NSVisualEffectStateActive)
        root.setMaterial_(NSVisualEffectMaterialPopover)
        root.setWantsLayer_(True)
        # maskImage (not just layer cornerRadius) so the window server clips
        # the blur backdrop and shapes the window shadow to the rounded rect;
        # the layer radius alone leaves both square at the corners.
        root.setMaskImage_(self._rounded_mask(RADIUS_PANEL))
        layer = root.layer()
        layer.setCornerRadius_(RADIUS_PANEL)
        try:
            layer.setCornerCurve_("continuous")
        except Exception:
            pass
        layer.setMasksToBounds_(True)
        layer.setBorderWidth_(0.5)

        for name, sym, size, cb, rect in specs:
            btn = KeyButton.alloc().initWithFrame_(rect).setup(sym, size, cb, self)
            root.addSubview_(btn)
            self.buttons[name] = btn

        panel.setContentView_(root)
        self.root = root
        self.apply_theme()

    def apply_theme(self):
        if is_dark():
            color = NSColor.whiteColor().colorWithAlphaComponent_(0.12)
        else:
            color = NSColor.blackColor().colorWithAlphaComponent_(0.08)
        self.root.layer().setBorderColor_(color.CGColor())
        for btn in self.buttons.values():
            btn.render_icon()
            btn._refresh_fill(0.01)

    # -- position persistence -------------------------------------------

    def _restore_frame(self, width, height):
        try:
            saved = json.loads(STATE_FILE.read_text())["frame"]
            return self._clamp(NSMakeRect(saved["x"], saved["y"], width, height))
        except Exception:
            return self._default_frame(width, height)

    @staticmethod
    def _default_frame(width, height):
        target = None
        for screen in NSScreen.screens():
            name = screen.localizedName() or ""
            if "Sidecar" in name or "iPad" in name:
                target = screen
                break
        if target is None:
            target = NSScreen.mainScreen()
        sf = target.visibleFrame()
        x = sf.origin.x + (sf.size.width - width) / 2.0
        y = sf.origin.y + 24
        return NSMakeRect(x, y, width, height)

    def _clamp(self, frame):
        best, best_dist = None, None
        cx = frame.origin.x + frame.size.width / 2.0
        cy = frame.origin.y + frame.size.height / 2.0
        for sf in display_frames():
            dist = (cx - (sf.origin.x + sf.size.width / 2.0)) ** 2 \
                + (cy - (sf.origin.y + sf.size.height / 2.0)) ** 2
            if best_dist is None or dist < best_dist:
                best, best_dist = sf, dist
        if best is not None:
            frame.origin.x = min(max(frame.origin.x, best.origin.x),
                                 best.origin.x + best.size.width - frame.size.width)
            frame.origin.y = min(max(frame.origin.y, best.origin.y),
                                 best.origin.y + best.size.height - frame.size.height)
        return frame

    def schedule_frame_save(self):
        # No timer per move event (drags emit dozens a second): just stamp a
        # deadline; the once-a-second tick performs the save after the drag
        # settles.
        if self._animating:
            return
        if self.visible:
            self._target_frame = self.panel.frame()
        self._save_due = time.time() + 1.0

    def rerender_icons(self):
        for btn in self.buttons.values():
            btn.render_icon()

    def reclamp_to_screens(self):
        # Display topology changed (Sidecar gone, resolution switch): pull a
        # stranded panel back onto a live screen. The move is not a user drag,
        # so suppress position persistence around it.
        if not self.visible:
            return
        frame = self.panel.frame()
        clamped = self._clamp(NSMakeRect(frame.origin.x, frame.origin.y,
                                         frame.size.width, frame.size.height))
        if (abs(clamped.origin.x - frame.origin.x) < 0.5
                and abs(clamped.origin.y - frame.origin.y) < 0.5):
            return
        self._animating = True
        self.panel.setFrame_display_(clamped, True)

        def settle():
            self._animating = False
        on_main_later(0.25, settle)

    def _save_frame(self):
        try:
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            f = self._target_frame or self.panel.frame()
            STATE_FILE.write_text(json.dumps({
                "frame": {"x": f.origin.x, "y": f.origin.y}
            }))
        except Exception as exc:
            log("frame save failed: %r" % exc)

    # -- actions ---------------------------------------------------------

    @staticmethod
    def _send_key(name):
        code = KEYCODES[name]
        CGEventPost(kCGHIDEventTap, CGEventCreateKeyboardEvent(None, code, True))
        CGEventPost(kCGHIDEventTap, CGEventCreateKeyboardEvent(None, code, False))

    def _send_hs(self, code):
        if not self.hs_binary:
            return
        subprocess.Popen([self.hs_binary, "-c", code],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _set_optimistic(self, state):
        # Give the daemon time to actually transition before the status poll
        # is allowed to overwrite the tapped-in state, or the mic flickers.
        self._optimistic_until = time.time() + 1.5
        self._set_voice_state(state)

    def _apply_polled_voice_state(self, state):
        # Guard evaluated here, not at enqueue time in the poll thread: a tap
        # landing between enqueue and execution must win over the stale poll.
        if time.time() >= self._optimistic_until:
            self._set_voice_state(state)

    def _on_mic(self):
        state = self.voice_state
        if state == "idle":
            self._send_hs("_G.GptVoice.start()")
            self._set_optimistic("recording")
        elif state == "recording":
            # Second tap = submit: daemon stops, pastes, and presses Enter.
            self._send_hs("_G.GptVoice.submit()")
            self._set_optimistic("processing")
        elif state in ("processing", "transforming"):
            self._send_hs("_G.GptVoice.cancel()")
            self._set_optimistic("idle")

    def _on_wand(self):
        if self.voice_state == "offline":
            return
        self._send_hs("_G.GptVoice.transform()")
        self._set_optimistic("transforming")

    # -- accessibility keyboard ------------------------------------------

    def _on_keyboard(self):
        # Decide and paint on the main thread; only the subprocess work goes
        # to a background thread. AssistiveControl cold-starts slowly
        # (seconds, that's macOS itself) — pulse until the tick confirms it.
        turning_on = not kb_running()
        self._kb_optimistic_until = time.time() + 3.0
        self._kb_expected = turning_on
        self._apply_kb_state(turning_on, turning_on)
        threading.Thread(target=self._toggle_kb, args=(turning_on,),
                         daemon=True).start()

    def _toggle_kb(self, turning_on):
        # Ground truth is the AssistiveControl process, not the defaults: they
        # can be left at "on" while the process is dead, and writing them does
        # not start the launchd job by itself — hence the explicit kickstart
        # (and the kill on hide, since launchd otherwise keeps it alive).
        try:
            value = "true" if turning_on else "false"
            for domain, key in (
                ("com.apple.universalaccess", "virtualKeyboardOnOff"),
                ("com.apple.Accessibility", "VirtualKeyboardEnabled"),
            ):
                subprocess.run(["defaults", "write", domain, key, "-bool", value],
                               timeout=5)
            if turning_on:
                subprocess.run(
                    ["launchctl", "kickstart",
                     "gui/%d/com.apple.AssistiveControl" % os.getuid()],
                    timeout=5)
            else:
                subprocess.run(["pkill", "-f", "Assistive Control"], timeout=5)
        except Exception as exc:
            log("keyboard toggle failed: %r" % exc)

    def _heal_offscreen(self):
        # Display topology changed under a visible panel (monitor ↔ virtual ↔
        # Sidecar): if it no longer intersects any live display, pull it back.
        # Full-outside check only, so edge-hugging drags are never fought.
        f = self.panel.frame()
        for sf in display_frames():
            if (f.origin.x < sf.origin.x + sf.size.width
                    and f.origin.x + f.size.width > sf.origin.x
                    and f.origin.y < sf.origin.y + sf.size.height
                    and f.origin.y + f.size.height > sf.origin.y):
                return
        self.reclamp_to_screens()

    def tick_kb(self):
        # Keyboard indicator tracks the real AssistiveControl process, so it
        # also follows native toggles. While a tap's optimistic window is
        # open, only a confirmed start may override the pending pulse.
        if self._save_due is not None and time.time() >= self._save_due:
            self._save_due = None
            self._save_frame()
        if not self.visible:
            return
        self._heal_offscreen()
        try:
            up = kb_running()
        except Exception:
            return
        # Inside a tap's grace window, reality may only CONFIRM the tapped
        # direction — a still-dying (or still-starting) process must not
        # flash the indicator back to its previous state.
        if time.time() < self._kb_optimistic_until and up != self._kb_expected:
            return
        self._apply_kb_state(up, False)

    def _apply_kb_state(self, on, pending):
        btn = self.buttons.get("keyboard")
        if btn:
            btn.set_tint("accent" if on else None)
            btn.set_pulsing(pending)
        # Layer mutations from timer context don't always reach the screen on
        # their own (stale icons observed after window drags) — flush.
        CATransaction.flush()

    # -- voice state ------------------------------------------------------

    def _set_voice_state(self, state):
        if state == self.voice_state:
            return
        self.voice_state = state
        mic = self.buttons.get("mic")
        wand = self.buttons.get("wand")
        if not mic or not wand:
            return
        offline = state == "offline"
        mic.set_button_enabled(not offline)
        wand.set_button_enabled(not offline)
        if state == "recording":
            mic.set_tint("red")
            mic.set_pulsing(True)
        elif state in ("processing", "transforming"):
            mic.set_tint("secondary")
            mic.set_pulsing(state == "processing")
        else:
            mic.set_tint(None)
            mic.set_pulsing(False)
        if state == "transforming":
            wand.set_tint("accent")
            wand.set_pulsing(True)
        else:
            wand.set_tint(None)
            wand.set_pulsing(False)

    def _poll_voice(self):
        while True:
            if not self.visible:
                time.sleep(1.0)
                continue
            state = "offline"
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(1.5)
                sock.connect(str(CONTROL_SOCK))
                sock.sendall(b"status\n")
                reply = sock.recv(64).decode("utf-8", "ignore").strip()
                sock.close()
                if reply in ("idle", "recording", "processing", "transforming"):
                    state = reply
            except OSError:
                state = "offline"
            on_main(self._apply_polled_voice_state, state)
            time.sleep(1.0)

    # -- show / hide -------------------------------------------------------

    def show(self):
        if self.visible:
            return
        self.visible = True
        panel = self.panel
        final = self._clamp(self._target_frame or panel.frame())
        self._target_frame = final
        start = NSMakeRect(final.origin.x, final.origin.y - 8.0,
                           final.size.width, final.size.height)
        self._animating = True
        panel.setFrame_display_(start, False)
        panel.setAlphaValue_(0.0)
        panel.orderFrontRegardless()

        NSAnimationContext.beginGrouping()
        ctx = NSAnimationContext.currentContext()
        ctx.setDuration_(0.20)
        ctx.setTimingFunction_(CAMediaTimingFunction.functionWithName_("easeOut"))
        panel.animator().setAlphaValue_(1.0)
        panel.animator().setFrame_display_(final, True)
        NSAnimationContext.endGrouping()

        def settle():
            self._animating = False
        on_main_later(0.25, settle)

    def hide(self):
        if not self.visible:
            return
        self.visible = False
        self._animating = True
        self._target_frame = self.panel.frame()
        panel = self.panel
        down = NSMakeRect(self._target_frame.origin.x,
                          self._target_frame.origin.y - 8.0,
                          self._target_frame.size.width,
                          self._target_frame.size.height)

        def done():
            self._animating = False
            if not self.visible:
                panel.orderOut_(None)
                panel.setFrame_display_(self._target_frame, False)

        def animations(ctx):
            # Must return None: PyObjC rejects non-void returns from this
            # block with a ValueError, aborting the hide mid-way.
            ctx.setDuration_(0.15)
            panel.animator().setAlphaValue_(0.0)
            panel.animator().setFrame_display_(down, True)

        NSAnimationContext.runAnimationGroup_completionHandler_(animations, done)

    # -- lifecycle ---------------------------------------------------------

    def _serve_control(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        try:
            OWN_SOCK.unlink()
        except OSError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(OWN_SOCK))
        srv.listen(2)
        while True:
            try:
                conn, _ = srv.accept()
                conn.settimeout(2.0)
                cmd = conn.recv(64).decode("utf-8", "ignore").strip()
                if cmd == "show":
                    on_main(self.show)
                    conn.sendall(b"ok\n")
                elif cmd == "hide":
                    on_main(self.hide)
                    conn.sendall(b"ok\n")
                elif cmd == "status":
                    conn.sendall(b"visible\n" if self.visible else b"hidden\n")
                elif cmd == "quit":
                    conn.sendall(b"ok\n")
                    conn.close()
                    on_main(self._shutdown)
                    return
                conn.close()
            except OSError as exc:
                log("control socket error: %r" % exc)
                time.sleep(0.5)

    def _watch_parent(self):
        parent = os.getppid()
        while True:
            if os.getppid() != parent:
                log("parent died, exiting")
                on_main(self._shutdown)
                return
            time.sleep(2.0)

    def _shutdown(self):
        self._save_frame()
        try:
            OWN_SOCK.unlink()
        except OSError:
            pass
        os._exit(0)

    @staticmethod
    def _kill_stale_instances():
        # hs.reload() resets the Lua supervisor's state but not Hammerspoon's
        # pid, so an untracked previous helper survives with a frozen ghost
        # panel stacked on ours. Singleton by force: one instance, ever.
        try:
            out = subprocess.run(
                ["pgrep", "-f", "ipad_overlay_app/overlay_app.py"],
                capture_output=True, text=True, timeout=5).stdout.split()
            for pid in out:
                if int(pid) != os.getpid():
                    os.kill(int(pid), signal.SIGKILL)
                    log("killed stale helper %s" % pid)
        except Exception as exc:
            log("stale-instance sweep failed: %r" % exc)

    def run(self, show_now=False):
        self._kill_stale_instances()
        threading.Thread(target=self._serve_control, daemon=True).start()
        if not show_now:
            threading.Thread(target=self._watch_parent, daemon=True).start()
        threading.Thread(target=self._poll_voice, daemon=True).start()
        if show_now:
            on_main(self.show)
        AppHelper.runEventLoop(installInterrupt=False)

    def smoke_test(self):
        missing = [name for name in (
            "escape", "doc.on.doc", "doc.on.clipboard", "mic", "wand.and.stars",
            "keyboard", "delete.left", "return",
            "arrow.up", "arrow.left", "arrow.down", "arrow.right",
        ) if NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None) is None]
        if missing:
            print("SMOKE TEST FAILED: missing symbols: %s" % missing, file=sys.stderr)
            return 1
        if len(self.buttons) != 12:
            print("SMOKE TEST FAILED: expected 12 buttons, got %d" % len(self.buttons),
                  file=sys.stderr)
            return 1
        print("SMOKE TEST PASSED: panel built, 12 buttons, all SF symbols resolved")
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--foreground", action="store_true",
                        help="show immediately (manual testing without Hammerspoon)")
    args = parser.parse_args()

    app = OverlayApp()
    if args.smoke:
        return app.smoke_test()
    app.run(show_now=args.foreground)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
