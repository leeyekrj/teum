# teum-cli
Python 3.9 이상이 필요합니다. Teum 앱과 같은 실제 한도를 AI가 읽는 로컬 CLI입니다. 별도 API 키나 AI 추론 없이 기존 CLI 로그인을 읽습니다.

## 조회
```bash
teum-cli status --json
teum-cli refresh
teum-cli budget --host codex --profile work --model gpt-6.1-sol --json
teum-cli budget --host agy --model claude-opus-5-5-high --json
teum-cli budget --host grok --json
teum-cli doctor
```
앱에서 감지한 `~/.codex-*` 프로필은 같은 이름의 `--profile`로 조회합니다. 예를 들어 `.codex-work`는 `--profile work`입니다. 실행 모델과 `CODEX_HOME`도 해당 프로필을 따릅니다. 계정·모델별 한도를 분리합니다. UI 경고 제외·숨김과 AI 예산은 별개입니다. 공통 한도와 해당 모델의 전용 한도 중 최소 잔여량을 고릅니다. 모델을 모르면 전용 한도는 판단하지 않습니다. 오래된 값·리셋 경과·조회 실패·Teum 연결 해제는 unknown입니다. Grok은 앱에서 Grok Bot 직접 조회를 연결한 뒤 조회·budget·gate를 지원합니다. `teum-cli budget --host grok --refresh --json`도 브라우저 없이 같은 사용량 API를 읽습니다. 이 Mac의 `grok` 명령은 기존 웹훅 클라이언트이므로 `teum-cli run --host grok`으로 호출하지 않습니다.

## 실제 조절
```bash
teum-cli run --host codex --profile work --model gpt-6.1-sol --prompt "작업 내용" --dry-run
teum-cli run --host agy --model gemini-4-argon-medium --prompt "작업 내용"
```
run으로 시작하는 **단발 작업**은 모델·effort·실행 대기·동시 실행 수를 실제 적용합니다. 기본은 20% 이하 절약, 5% 이하 긴축, 0% 소진 시 새 실행 중지입니다. dry-run은 계획만 봅니다. 이 CLI가 시작한 프로세스만 감시하고, 새로 확인된 소진은 해당 그룹에 SIGINT를 보냅니다. 다른 세션을 종료하거나 전역 모델·권한을 바꾸지 않습니다. 서버의 토큰 생성 속도를 직접 바꾸지는 못합니다.

이미 열린 세션에는 **훅의 권고 문맥**이 들어갑니다. 지원하지 않는 모델 변경을 했다고 보고하지 않습니다. PreToolUse는 비동기이고 훅은 네트워크를 호출하지 않습니다. 반복 문맥은 세션당 60초에 한 번입니다. 새 연결은 새 세션 또는 호스트의 훅·스킬 다시 불러오기 후 적용됩니다.

## 기준 변경
```bash
teum-cli policy show
teum-cli policy set --stream claude --conserve 25 --critical 5 --stop-at 1
teum-cli policy set --auto-switch off
```
run과 gate는 소진이면 75, 미확인이면 78입니다. budget은 JSON 조회이므로 성공 시 0입니다. 설정은 Teum의 policy.json에만 저장하며 앱 설정은 덮어쓰지 않습니다.

## 이번 세션에서만 받을 알림
기준과 대응을 사용자와 합의한 뒤 현재 호스트의 실제 세션 ID로 등록합니다. 다른 세션의 ID를 재사용하지 않습니다.
```bash
teum-cli watch add --host codex --profile work --session "$CODEX_THREAD_ID" --window weekly --below 10 --message "진행 상태를 남기고 새 작업을 멈추기" --hours 12 --json
teum-cli watch list --json
teum-cli watch check --host codex --session "$CODEX_THREAD_ID" --json
teum-cli watch cancel --id 등록할때받은ID
```
`--session`을 생략하면 TEUM_SESSION_ID, CODEX_THREAD_ID, CLAUDE_SESSION_ID, KIRO_SESSION_ID 중 존재하는 값을 씁니다. ID를 모르면 임의로 만들지 말고 현재 호스트의 세션 정보를 확인하세요. `--window auto`는 그 모델에 적용되는 가장 낮은 한도, short는 하루 미만, weekly는 6~8일 주간 한도, 그 외 값은 실제 한도 ID입니다. `--model`을 주면 해당 모델의 전용 한도도 확인합니다. 잔여량이 기준 **이하**이고 데이터가 신선할 때만 전달합니다.

설치된 훅이 실행되는 다음 시점에 해당 세션에 한 번 문맥으로 들어갑니다. 일반 사용량 문맥의 60초 제한과 별개입니다. 훅이 없는 호스트나 현재 세션은 `watch check`를 작업 경계에서 호출합니다. 추론 중인 세션에 메시지를 강제로 주입하거나 세션을 종료하는 기능은 아닙니다. 실제 대응은 합의 내용에 따라 세션이 수행합니다. 기본 12시간, 최대24시간 뒤 만료되며 전달·취소 후 재발하지 않습니다. 전역 policy와 UI 경고 제외 설정을 바꾸지 않습니다. 앱 설정의 ‘세션 알림’에서 활성 조건·대상·내용·만료 시각과 종료 내역을 확인하고 취소할 수 있습니다. 종료 내역은 7일 뒤 정리됩니다.

## 주간 배분 계획
```bash
teum-cli plan --json
```
앱의 ‘배분 계획’과 같은 계산을 읽습니다. 계정별 보호량을 뺀 실제 주간 잔여량을 다음 리셋까지 분배한 %p 목표입니다. 계정마다 한도 크기가 달라 토큰·작업 시간으로 환산하지 않습니다. 리셋 뒤 100% 가정은 예상으로 구분하며, 자동 모델·계정 전환을 실행하지 않습니다.
‘오늘의 목표’와 ‘배분 계획’은 하단 네 점으로 이동하는 독립된 세 번째·네 번째 페이지입니다. 오늘 표는 주간 잔여·관측 사용/목표·남은 몫을 나란히 비교합니다. 목표 수치를 눌러 오늘 값만 조정하거나, 설정의 ‘목표·선호 AI’에서 반복 목표와 선호 순서를 정합니다. 배분표는 계정×날짜로 비교하며 오늘의 남은 목표를 먼저 반영하고 나머지를 리셋 전까지 나눕니다. 기간·대상·보호량은 ‘배분 설정’에서 관리합니다. 목표가 소진된 계정은 우선 추천에서 빠집니다. 첫 조회 전 사용량과 조회 사이 리셋에 가려진 소비는 누락될 수 있습니다. plan JSON의 `todayGoals`는 관측 시작 시각, 목표·관측 사용·남은 %p와 측정 한계를, `preferredStreams`는 선호 순서를 제공합니다.

## 설치·제거
```bash
python3 cli/install.py --trust-codex
python3 cli/install.py --uninstall
```
저장소를 클론한 폴더에서 실행합니다. CLI가 이미 설치된 경우 기존 래퍼를 먼저 제거한 뒤 소스용 설치를 진행하세요. 이 고급 설치는 Claude·Codex·AGY·Kiro에 공통 스킬과 캐시 기반 훅을 추가합니다. 기존 훅·모델·YOLO·권한은 보존하고 변경 전 설정은 integration-backups에 저장합니다. 제거도 Teum 항목만 지웁니다.

공식 규격: [Codex Hooks](https://learn.chatgpt.com/docs/hooks), [Claude Hooks](https://code.claude.com/docs/en/hooks). AGY·Kiro는 설치된 로컬 훅 규격을 대조합니다.
