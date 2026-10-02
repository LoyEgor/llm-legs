import json
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
            drivers.append({"name": name.strip(), "speed": int(fields[0]), "seats": int(fields[1])})
    drivers.sort(key=lambda d: (-d["speed"], d["name"]))
    return drivers


def route_a(drivers):
    return [d["name"] for d in drivers if d["seats"] > 2]


if __name__ == "__main__":
    print(json.dumps(route_a(load_drivers(sys.argv[1]))))
