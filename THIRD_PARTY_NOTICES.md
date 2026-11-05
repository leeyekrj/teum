# 외부 소스와 라이선스 고지
Teum의 MIT 라이선스는 아래 원저작권과 라이선스 고지를 대체하지 않습니다. 전문은 `licenses/`와 앱의 `Contents/Resources/licenses/`에 포함합니다.

## 직접 포함한 소스
**[QuotaBar](https://github.com/QuotaBar/QuotaBar)** — Copyright (c) 2026 GiantAccel, LLC, MIT. `Vendor/QuotaCore`, `Vendor/QuotaModel`, `Vendor/QuotaRelay`의 기반 소스와 공급자 로고의 직접 출처입니다. 원본 고지는 [LICENSE-QuotaBar.txt](licenses/LICENSE-QuotaBar.txt)입니다. 기반 소스의 로컬 체크아웃은 upstream 커밋 `2dda67f09786bc978f2deaf7452d989b0f457310`이며 Teum용 수정이 포함되어 있습니다. 원본 제품과는 별도 프로젝트입니다.

## 상위 프로젝트에서 명시한 참고·재사용 출처
QuotaBar의 [Acknowledgements](https://github.com/QuotaBar/QuotaBar#acknowledgements)에 기재된 프로젝트입니다. 직접 포함과 동작·디자인 참고를 구분하면서 고지를 보존합니다.

| 프로젝트 | 저작권자 | Teum과의 관계 | 전문 |
|---|---|---|---|
| [OpenUsage](https://github.com/robinebers/openusage) | Copyright (c) 2026 Robin Ebers | QuotaBar의 페이스·캐시·프록시 등 동작 참고 출처. 관련 주석을 보존합니다. | [MIT](licenses/LICENSE-OpenUsage.txt) |
| [CodexBar](https://github.com/steipete/CodexBar) | Copyright (c) 2026 Peter Steinberger | QuotaBar의 공급자 조회 형식·동작 참고 출처. 관련 주석을 보존합니다. | [MIT](licenses/LICENSE-CodexBar.txt) |
| [codex-island](https://github.com/ericjypark/codex-island) | Copyright (c) 2026 Eric Park | QuotaBar가 명시한 노치 표현·모션의 참고 출처입니다. | [MIT](licenses/LICENSE-codex-island.txt) |
| [theSVG](https://github.com/GLINCKER/thesvg) | Copyright (c) 2025 thesvg.org | QuotaBar가 명시한 공급자 로고 벡터 원본 출처입니다. | [MIT](licenses/LICENSE-theSVG.txt) |

## 이미지·폰트·시스템 라이브러리
`Sources/Teum/Resources/logos/`의 Claude·Codex·Grok·Kiro·Antigravity 이미지는 QuotaBar 배포본에서 가져왔으며, 공개 준비 시 픽셀 내용이 동일함을 확인했습니다. 앱 아이콘은 `scripts/icon.swift`로 직접 그립니다. 로고의 상표권과 제품명 권리는 각 소유자에게 있으며, 코드의 MIT 라이선스가 상표 사용 허락을 의미하지는 않습니다. Teum은 이들 서비스의 공식·제휴·후원 앱이 아닙니다.

QuotaBar가 사용하는 Instrument Sans 폰트는 Teum에 포함하지 않습니다. Teum에는 TTF·OTF·WOFF 파일이 없으며 macOS 시스템 글꼴·SF Symbols와 시스템 프레임워크를 사용합니다. 별도의 Swift Package·Python 패키지 의존성을 내려받지 않습니다. Python CLI는 표준 라이브러리를 사용합니다.
