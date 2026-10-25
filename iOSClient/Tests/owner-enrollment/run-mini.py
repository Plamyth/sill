"""Vision 담당 owner·job·저장 경로를 사용하는 통합 격리 검사 진입점."""
from pathlib import Path
import runpy
import sys
if sys.argv[1:]:
    raise SystemExit('Vision 검사는 인자 없이 통합 실행합니다.')
runpy.run_path(str(Path(__file__).resolve().parents[3] / 'Tests/checks/vision-owner-enrollment/run-mini.py'), run_name='__main__')
