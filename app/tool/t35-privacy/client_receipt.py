"""Require every exact T35 privacy widget regression in a Flutter JSON receipt."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t27"))
from ci_check import flutter_receipt

REQUIRED = (
    "named privacy route reads account and verifies persisted correction",
    "frozen relogin gates business routes until explicit cancellation and readback",
    "unknown account never starts assessment or growth",
    "phone closure submits one fresh proof and retires the local lease",
    "my tab opens the formal privacy page",
    "lost closure receipt remains visible on login after unauthorized readback",
)


def main():
    with Path(sys.argv[1]).open(encoding="utf-8") as output:
        lines = output.readlines()
    results = [flutter_receipt(lines, int(sys.argv[2]), name) for name in REQUIRED]
    for name, result in zip(REQUIRED, results, strict=True):
        print(f"{result}: {name}")
    return 0 if all(result == "PASS" for result in results) else 1


if __name__ == "__main__":
    sys.exit(main())
