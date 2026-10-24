#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys

path = Path(__file__).resolve().parents[1] / 'vision-sentry/run.py'
spec = importlib.util.spec_from_file_location('vision_sentry_checks', path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.CHECK_SUITE = 'vision-sentry-v2'
sys.exit(runner.main())
