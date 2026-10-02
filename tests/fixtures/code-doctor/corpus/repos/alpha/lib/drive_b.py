import sys


def load_drivers(path):
    drivers = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, rest = line.partition("=")
            fields = rest.split(",")
            drivers.append({"name": name.strip(), "speed": int(fields[0]), "seats": int(fields[1] or 0)})
    drivers.sort(key=lambda d: (-d["speed"], d["name"]))
    return drivers


def fastest(drivers, count):
    picked = []
    for driver in drivers:
        if len(picked) >= count:
            break
        picked.append(driver["name"])
    return picked


if __name__ == "__main__":
    print(" ".join(fastest(load_drivers(sys.argv[1]), 3)))
