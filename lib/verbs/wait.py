#!/usr/bin/env python3
"""guard wait: argv in, capped text out; lib/wait.py does the waiting."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
import wait  # noqa: E402

if __name__ == "__main__":
    sys.exit(wait.main(sys.argv[1:]))
