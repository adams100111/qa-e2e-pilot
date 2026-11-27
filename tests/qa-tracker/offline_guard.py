"""The tracker suite never reaches the network. Every test file imports this module.

Two barriers: the variable `HttpTransport` reads (a transport with the real opener refuses every
call; child processes inherit it, so a CLI run in a subprocess is covered), and
`urllib.request.urlopen` itself, replaced for this process, which also covers a test that clears
the environment. Either one fails the test with a traceback, never with a caught error.
"""
import os
import urllib.request

OFFLINE_ENV = "QA_KIT_TRACKER_OFFLINE"


def _refuse(*args, **kwargs):
    raise AssertionError("the tracker suite tried to reach the network")


os.environ[OFFLINE_ENV] = "1"
urllib.request.urlopen = _refuse
