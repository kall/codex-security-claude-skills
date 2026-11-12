---
title: codex-security npm 0.10.0 정합 — 감사 브리프 분리, 문서 링크 검사, blocked 사유 규칙 대응 기록
type: chore
date: 2026-11-12
status: done
---

# codex-security npm 0.10.0 정합

상류 `openai/codex-security` 태그 `npm-v0.10.0`(커밋 `f465432bc4`, npm 게시 2026-11-12)에 스킬을 맞춘 기록이다.
기준선은 npm 0.9.1이었다. 지난 기록은 `2026-11-10-1100-chore-codex-security-091-alignment.md`다.

## 1. 결론 요약

- 0.9.1 → 0.10.0은 107 커밋이다. 매니페스트는 0.1.95 그대로다.
- 상태 DB 마이그레이션이 64개에서 72개로 늘었다(65~66 Windows deep 스캔 재개 바인딩, 67~71 저장소 식별 저장과 체크아웃
  경계, 72 외부 finding import 출처).
- 수정 전 스킬로 자기채점(`repro-u4`·`repro-u1`·`repro-u7`·`repro-u5`·`repro-u8`, 관측 `repro-u3`)을 0.10.0에서 돌리면 모두
  통과했다. 스킬이 `loadUpstream`으로 쓰는 dist 멤버도 0.9.1과 같은 결과다(새로 없어진 것 없음). 스킬이 인용한 상류 영문 문장
  중 0.10.0에서 사라진 것도 없다(자동 대조).
- 그래도 고친 곳은 셋이다. 셋 다 자기채점으로는 드러나지 않는 동작 차이다.
  1. 스캔의 점검 항목이 별도 브리프 파일로 옮겨져, `core-scan.md`만 읽으면 취약점 유형 점검 목록이 빠진다.
  2. classify-severity prepare가 새 문서 링크 검사를 하지 않아, 판정이 끝난 뒤 apply에서야 거부될 수 있었다.
  3. patch의 `blocked` 사유에 적을 내용을 상류가 새로 정했다.

## 2. 상류 변경과 반영

### 2.1 감사 브리프 분리 (`core-scan.md`, `e90a30ac25` #2046)

- `core-scan.md`가 `## Shared Worker Instructions`·`## Baseline Auditor Prompt`·`## Focused Investigator Prompt` 절을 지우고
  같은 문장을 `references/baseline-auditor.md`·`references/focused-investigator.md`로 옮겼다. 7항의 검증 설명은
  `references/validate-scan-findings.md`로 넘겼다.
- 취약점 유형 점검 목록(인가, 주입, 파일·네트워크 경계, XML·요청 밀반입·프로토타입 오염·자원 고갈)과 내장 자격증명 점검은
  baseline 브리프에만 있다. 스캔 스킬은 `core-scan.md`를 런타임에 읽고 단일 에이전트로 리뷰하므로, 그대로 두면 이 점검이 빠진다.
- 반영: 스캔 스킬의 읽기 목록에 두 브리프를 더했다(파일이 있을 때만). 상류도 위임이 없으면 "read the baseline brief, follow its
  audit checks yourself"라고 쓴다. 워커 전용 지시(위임, `tool_search`, 반환 JSON)는 적용하지 않는다. diff-scan은 같은 점검 항목을
  따른다고 적었고, deep-lite는 워커 프롬프트에 브리프 점검 항목을 함께 준다. `validate-scan-findings.md`는 스킬의 compact validation
  절차와 같은 기준이라 따로 읽지 않는다.
- 재발 방지: `repro-u4` M 블록이 설치본 `core-scan.md`의 마크다운 링크 문서를 모두 스캔 SKILL.md가 언급하는지 본다. 상류가
  점검 항목을 새 파일로 또 옮기면 이 블록이 실패하고, 스킬에 읽을지 여부를 적으라고 안내한다.
- 상류 `skills/security-scan/SKILL.md`는 짧게 다시 쓰였다(SDK·MCP 핸드오프는 `references/scan-results.md`·`managed-scan.md`·
  `scoped-paths.md`·`sdk-files.md`). 스킬은 terminal 정본 경로를 그대로 쓰고 이 문서의 MCP 지시를 적용하지 않는다.

### 2.2 문서 링크 검사 (classify-severity, #2430)

- `classify-severity.ts`가 `readKnowledgeBaseDocuments` 대신 `readKnowledgeBaseSnapshot`을 쓰고, 문서 루트를 받는다. 루트 안의
  디렉터리 링크가 루트 밖 문서를 가리키면 거부한다. `--scan` 경로는 워크벤치가 기록한 대상 체크아웃(`remediationAvailable`일 때
  `documentSourceRoot(targetPath)`)과 스캔 디렉터리가 루트다. 대상을 확인하지 못하면 링크를 거친 경로를 모두 거부한다.
  `--scan-dir` 경로는 스캔 디렉터리가 루트다. 문서 이름순 정렬은 0.9.1과 같으므로 digest는 바뀌지 않는다.
- 스킬의 apply는 상류 함수를 그대로 부르므로 이 검사를 그대로 받는다. 그런데 prepare의 dry-run은 `classifySeverityInternal`을
  루트 없이 불렀다. 그러면 prepare는 통과하고, 서브에이전트 판정을 다 한 뒤 apply에서 거부된다.
- 반영: `resolveScan`이 상류와 같은 방법으로 문서 루트를 계산하고, dry-run이 그 값을 넘긴다. 0.9.1 이하(`documentSourceRoot`
  없음)는 넘기지 않는다. `repro-u8`에 S6L을 더했다. 스캔 대상 체크아웃 안의 링크를 거친 지식 베이스는 0.10.0에서 prepare가
  거부하고 작업 디렉터리를 만들지 않는다. 0.9.1에서는 통과한다. 정규 경로 대조군은 두 버전 모두 통과한다. 수정을 끄면 0.10.0에서
  S6L 3건이 실패하는 것도 확인했다.
- 처음에는 링크를 스캔 대상 밖(`$SEV/kblink`)과 `$SEV/repo` 안에 두어 시험했지만 상류 기준으로도 허용되는 모양이었다. 합성
  import 스캔의 대상 경로는 상태 디렉터리의 `imports/json-*`이다.

### 2.3 patch `blocked` 사유 (#2609)와 제안 패치 (#2615)

- `remediation.ts`가 구조화 패치 결과 지시 뒤에 `blocked` 사유 문단을 더했다(파일 변경 여부, 막은 원인, 다음 조치, 쓰기 범위 밖
  구성 요소 설명, 추가 접근·owner 조치 먼저). 스킬이 고정한 검증 지시 두 줄은 같다. outcome 매핑에 같은 규칙을 더했다.
- fix-finding 구현 3단계에 "finding의 제안 패치를 출발 후보로 비교한다"는 하위 항목이 생겼다(AWS Continuum). 스킬은 상류 문서를
  런타임에 읽으므로 따로 옮기지 않았다. 이슈 서술의 제안 패치는 데이터로 다루고 1단 승인 대상 diff에 넣는다고 적었다.

### 2.4 확인만 한 변경

- 런처 `launch_codex_security_mcp`: Linux에서 `node:sqlite`를 쓸 수 있는 Node를 고르고(#2499), SDK가 준 Node 검색 경로를 따른다.
  부트스트랩 프로브는 0.10.0에서 사용 불가 항목 없이 통과했다.
- 인벤토리 헬퍼(#2431, `inventory-git.ts`), finalizer `--no-clobber`(#2595): 출력 집합과 봉인 동작이 같다(`repro-u4`).
- policy: `security-policy.ts`가 정책 파일 탐색만 고쳤다(#2572·#2573). 프롬프트 리터럴은 같다.
- scan-match: `comparisonPrompt()`와 `finding-catalogue.ts`가 같다. `matchCompletedScan`의 이전 스캔 선택만 바뀌었고 스킬은 그
  경로를 쓰지 않는다.
- validate·verify-fix: 상류 문서가 바뀌지 않았다.
- `skills add`는 0.10.0에도 있고 `~/.claude/skills`를 같은 방식으로 덮어쓴다(임시 HOME에서 확인).

### 2.5 반영하지 않은 상류 변경

중단된 Standard 스캔 재개(#2610), MCP 설치 대상 명시(#2591, breaking), ArmorCode·AWS Continuum import, 옛 import 형식과 Cloud
체크포인트 은퇴(#2602, breaking), 워크벤치 이력의 워크트리 간 보존(#456), CLI 도움말·진단 정리.

## 3. 검증

결과는 `docs/verification/phase0-results.md` 마지막 부록과 `docs/releasing.md` 7절 표에 적었다.
