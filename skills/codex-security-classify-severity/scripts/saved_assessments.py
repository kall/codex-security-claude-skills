"""저장된 심각도 평가 행을 **읽기 전용**으로 돌려준다(codex-security-classify-severity 전용 보조).

왜 필요한가: 상류 `SeverityStore.checkpoint().load`는 `workbench_db.py severity-classification`의
`begin`으로 저장 행을 받는다. `begin`은 스캔의 선택 행(`scan_severity_classifications`)을 새 선택·digest로
덮어쓰는 **쓰기**다. `prepare`가 이것을 부르면, 사용자가 서브에이전트 단계에서 멈췄을 때 이전의 완료된
분류가 publish에서 `incomplete`로 바뀐다. 그래서 `prepare`는 같은 행을 읽기 전용 연결로만 읽는다.
실제 `begin`·`save`는 `apply`에서 상류 코드(SeverityStore)가 한다.

재구현하지 않는다: 행 조회는 플러그인 `workbench_severity.assessments()`(상류 SELECT와 13키 camelCase
매핑)를 그대로 부른다. 연결 방식은 상류 `read_classification()`과 같다(`file:…?mode=ro`, BEGIN).
digest로 거르는 일은 호출자(classify_severity.mjs)가 상류 `matchingAssessments`와 같은 규칙으로 한다.

실행: <python> -I -X utf8 -B saved_assessments.py <pluginRoot> <stateDir>  (stdin: {"findingIds": [...]})
출력: {"database": bool, "assessments": [<선택 순서의 저장 행>]}
"""

import json
import sqlite3
import sys
from contextlib import closing
from pathlib import Path
from urllib.parse import quote


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: saved_assessments.py <pluginRoot> <stateDir>", file=sys.stderr)
        return 1
    plugin_root, state_dir = Path(sys.argv[1]), Path(sys.argv[2])
    payload = json.load(sys.stdin)
    finding_ids = payload.get("findingIds")
    if not isinstance(finding_ids, list) or not all(isinstance(item, str) for item in finding_ids):
        print("findingIds must be a list of strings", file=sys.stderr)
        return 1
    sys.path.insert(0, str(plugin_root / "scripts"))
    import workbench_severity  # noqa: E402  (플러그인 모듈 — 상류 조회 그대로)

    database = state_dir / "workbench.sqlite3"
    if not database.is_file():
        print(json.dumps({"database": False, "assessments": []}))
        return 0
    uri = f"file:{quote(str(database), safe='')}?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=5)) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute("BEGIN")
        if (
            connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' "
                "AND name = 'finding_severity_assessments'"
            ).fetchone()
            is None
        ):
            print(json.dumps({"database": True, "assessments": []}))
            return 0
        rows = workbench_severity.assessments(connection, finding_ids)
    print(json.dumps({"database": True, "assessments": rows}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
