from gen_pkg.formats.table import render
import gen_pkg.formats.grid


def main():
    return render([]) + gen_pkg.formats.grid.cells()
