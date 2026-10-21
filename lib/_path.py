"""The import convention for lib/: the names are policy.cost, broker.server, verbs.run, refusals, never a bare records.

A script under a subdirectory of lib/ starts with

    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    import _path  # noqa: E402,F401

and a script in lib/ itself only imports it. Python puts the script's own directory first on sys.path, so a script in
lib/broker/ would also see records.py as a top-level module named records, a second copy whose Refused no handler
catches. This drops every subdirectory of lib/ from sys.path and puts lib/ first."""
import os
import sys

LIB = os.path.dirname(os.path.realpath(__file__))
HARNESS = os.path.dirname(LIB)

sys.path[:] = [LIB] + [p for p in sys.path
                       if os.path.realpath(p or os.curdir) != LIB
                       and not os.path.realpath(p or os.curdir).startswith(LIB + os.sep)]
