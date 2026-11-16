"""The model command `duck hatch` runs (DUCK_HATCH_CMD): prompt on stdin, reply on stdout.
Calls `claude -p` exactly like the one-shot conditions and logs every call.
Usage: python3 -I model_cmd.py <log dir>"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import call_model  # noqa

log_dir = sys.argv[1]
os.makedirs(log_dir, exist_ok=True)
n = len([f for f in os.listdir(log_dir) if f.endswith(".prompt.txt")]) + 1
text, meta = call_model(sys.stdin.read(), os.path.join(log_dir, f"call{n}"))
if text is None:
    sys.stderr.write(f"model call failed: {meta}\n")
    sys.exit(1)
sys.stdout.write(text)
