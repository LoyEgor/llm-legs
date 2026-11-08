// The chats app's microphone: the input at 16 kHz mono int16 in 20 ms frames (320 samples), the iPad stream
// format of transcriptions-gpt's receiver (its ipad-mic/PROTOCOL.md). Each output sample averages the input
// samples it covers, a box low-pass that is plenty for speech.
class Mic16k extends AudioWorkletProcessor {
  constructor() {
    super();
    this.step = sampleRate / 16000;
    this.pos = 0;
    this.sum = 0;
    this.n = 0;
    this.frame = new Int16Array(320);
    this.k = 0;
  }

  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch) return true;
    for (let i = 0; i < ch.length; i++) {
      this.sum += ch[i];
      this.n++;
      if (++this.pos < this.step) continue;
      this.pos -= this.step;
      const v = Math.max(-1, Math.min(1, this.sum / this.n));
      this.frame[this.k++] = v < 0 ? v * 32768 : v * 32767;
      this.sum = 0;
      this.n = 0;
      if (this.k === 320) {
        this.port.postMessage(this.frame.buffer, [this.frame.buffer]);
        this.frame = new Int16Array(320);
        this.k = 0;
      }
    }
    return true;
  }
}

registerProcessor('mic16k', Mic16k);
