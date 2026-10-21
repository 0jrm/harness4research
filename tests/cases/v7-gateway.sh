# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== the model and network gateway"
gw() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import gateway as g; print(eval(sys.argv[2]))' "$here" "$1"; }
expect gateway-net-allow ok "^\(\['pypi.org:443', 'localhost:8080'\], \['bad/host'\]\)$" -- gw 'g.net_allow("x: 1\nnet_allow: PyPI.org, localhost.:8080 bad/host")'
expect gateway-net-default ok "^\(\['pypi.org:443', 'files.pythonhosted.org:443', 'conda.anaconda.org:443', 'repo.anaconda.com:443'\], \[\]\)$" -- gw 'g.net_allow("x: 1")'
expect gateway-net-none ok '^\(\[\], \[\]\)$' -- gw 'g.net_allow("net_allow: none")'
expect gateway-host-port ok "^\('localhost:3128', None, None\)$" -- gw '(g.host_port("LocalHost.:3128"), g.host_port("a@b:1"), g.host_port("a:b:c"))'
expect gateway-scrub-split ok '^a\[removed by the gateway\]b \[removed by the gateway\] 2$' -- gw '(lambda s: (b"".join(s.feed(c) for c in (b"aSECR", b"ET-KEYb SEC", b"RET-KEY")) + s.flush()).decode() + " " + str(s.removed))(g.Scrubber(["SECRET-KEY"]))'
