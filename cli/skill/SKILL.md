---
name: teum-cli
description: "Teum 사용량·리셋 시각을 조회해 Claude Code·Codex(다중 프로필 포함)·AGY Claude/Gemini·Kiro의 작업 예산을 조절한다. 장시간 작업, 병렬 AI 실행, 저잔량·중단·모델 선택을 판단하거나 사용량을 확인할 때 사용한다."
---
# Teum 사용량 연동
실행 파일은 `~/.local/bin/teum-cli`, 앱 배포본의 구현은 `Teum.app/Contents/Resources/cli/teum_cli.py`이며, 소스 설치는 클론 폴더의 `cli/teum_cli.py`를 사용합니다. `teum-cli --help`에서 실제 명령을 확인합니다.

## 현재 세션 판단
자기 호스트·프로필·모델에 해당하는 한도만 봅니다. 다른 계정의 고갈로 현재 작업을 멈추지 않습니다.
```bash
teum-cli budget --host codex --profile work --model gpt-6.1-sol --json
teum-cli budget --host claude --model opus --json
teum-cli budget --host agy --model gemini-4-argon-medium --json
teum-cli budget --host kiro --model claude-opus-5.5 --json
```
- Codex는 `CODEX_HOME`으로 기본(`~/.codex`)과 추가 프로필(`~/.codex-<이름>`)을 구분합니다. AGY는 실제 모델명으로 Claude/GPT 또는 Gemini 그룹을 선택합니다.
- `fresh:false`·`stage:unknown`이면 `teum-cli refresh` 후 다시 봅니다. 과거 값으로 0%나 100%를 추정하지 않습니다. 조회는 AI 추론을 쓰지 않고 로그인도 전환하지 않습니다.
- `normal`: 현재 작업 유지. `conserve`: 반복·큰 입력·새 병렬 작업을 줄이고 `recommended_model` 검토. `critical`: 순차 실행과 마무리·인계 우선. `pause`: 새 추론 작업 중지, 현재 상태와 재개 조건을 파일에 남깁니다.
- 장시간 작업은 `poll_seconds` 간격으로 확인합니다. 모델별 한도가 있는 Claude는 `--model`에 실제 모델을 줍니다. 모델을 모르면 공통 한도만 판단됩니다.
- UI의 경고 제외/숨김은 **AI 예산 제외가 아닙니다.** 임계값은 `teum-cli policy show` 또는 `policy set`으로 별도 관리합니다. 사용자가 이번 작업에 준 예산·중단 조건이 우선합니다.

## 새 AI 작업을 실제로 조절
```bash
teum-cli run --host codex --profile work --model gpt-6.1-sol --prompt "범위가 정해진 작업" --dry-run
teum-cli run --host agy --model gemini-4-argon-medium --prompt "범위가 정해진 작업"
```
`run`은 단발 실행용입니다. 새 프로세스의 모델·effort·실행 대기·동시 실행 수를 적용합니다. 소진/미확인 상태면 실행하지 않습니다. 실행 중 새로 확인된 소진은 **자기가 시작한 프로세스 그룹에만 SIGINT**를 보내며 강제 종료하지 않습니다. 다른 앱·세션을 종료하거나 전역 기본 모델을 바꾸지 않습니다. 권한·샌드박스 옵션은 추가하지 않습니다.

현재 네이티브 세션에 들어오는 훅은 **권고 문맥**입니다. 훅이 그 세션의 모델·서버 토큰 속도를 이미 바꿨다고 말하지 않습니다. 실제 지원되는 `/model`·호스트 API 또는 새 `run` 실행을 사용하고, 지원하지 않으면 중단·인계 후 사용자가 선택하게 합니다. 이 스킬은 새 하위 에이전트 실행 권한을 부여하지 않습니다.

## 명령과 결과
- `status --json`: 연결된 계정의 값·윈도·freshness. `refresh`: 실제 값 새로 읽기.
- `gate ...`: 사용 가능 0, 소진 75, 미확인 78. `budget`은 상태를 JSON으로 읽는 용도라 성공 시 0.
- `policy set --stream claude --conserve 20 --critical 5 --stop-at 0`: 해당 스트림만 기준 변경. `--auto-switch off`로 자동 모델 변경 해제.
- `doctor`: 수집기·데이터·설치된 연결 확인.
설정·캐시는 `~/Library/Application Support/Teum/`입니다. 인증 토큰을 CLI 출력·스킬·인계 문서에 복사하지 않습니다.

## 합의한 일회성 세션 알림
사용자와 이번 세션의 기준·대응을 합의한 경우에만 등록합니다. 예를 들어 주간 잔여10%에서 인계하고 멈추기로 했을 때:
```bash
teum-cli watch add --host codex --profile work --session "$CODEX_THREAD_ID" --window weekly --below 10 --message "진행 상태를 남기고 새 작업을 멈추기" --hours 12 --json
teum-cli watch list --json
teum-cli watch check --host codex --session "$CODEX_THREAD_ID" --json
teum-cli watch cancel --id 등록결과의ID
```
실제 현재 세션 ID를 사용합니다. 생략 시 TEUM_SESSION_ID / CODEX_THREAD_ID / CLAUDE_SESSION_ID / KIRO_SESSION_ID를 확인합니다. 없으면 현재 호스트의 세션 정보를 확인하며, 임의 ID나 다른 세션 ID로 자동 전달된다고 말하지 않습니다. 호스트 훅의 session_id/conversationId/sessionId와 같아야 합니다. `--host`와 프로필·모델도 자신의 실제 실행 환경에 맞춥니다.

`--window auto`는 해당 모델에 적용되는 가장 낮은 한도, short는 하루 미만, weekly는6~8일 한도, 다른 값은 실제 window ID입니다. 기준 이하는 포함되며 오래된/리셋 전 값으로 발동하지 않습니다. 설치된 훅의 다음 호출 또는 watch check에서 한 번 전달하고 끝납니다. 훅 미지원·기존 세션에서 훅이 다시 로드되지 않았다면 도구 실행·작업 구간 사이에 watch check를 호출합니다. 알림은 합의된 대응을 상기시키며, 프로세스 종료·모델 변경을 자동 실행하지 않습니다. 추론 중 실시간 강제 주입으로 설명하지 않습니다. 기본12시간/최대24시간 만료, 작업이 끝나면 남은 조건을 취소합니다. 앱 설정 ‘세션 알림’에서도 확인·취소할 수 있습니다.

`teum-cli plan --json`은 실제 주간 한도와 리셋 일정에 따른 계정별 %p 배분 권고입니다. 미래100%는 예상이고 계정간 토큰/시간 등가나 자동전환을 뜻하지 않습니다.
