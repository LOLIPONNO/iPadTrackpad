# iPadTrackpad

iPad를 macOS용 초저지연 멀티터치 트랙패드로 활용하기 위한 네이티브 Swift 6 / SwiftUI 프로젝트입니다.  
Apple `Network.framework`(Bonjour + TCP 제어 + UDP 터치 스트림)를 기반으로 **Wi-Fi 무선 연결**과 **USB 유선 연결**을 모두 지원합니다.

---

## 주요 기능

- **초저지연 바이너리 터치 파이프라인**
  - `JSON`/`Codable` 직렬화 오버헤드 없이 고정 폭 바이너리 프레임(8B 헤더 + 14B 프레임 서브헤더 + 16B `TouchPoint`) 전송
  - 제어/핸드셰이크/시스템 제스처는 `TCP`, 연속 터치 프레임은 `UDP`로 분리 전송
  - 120Hz ProMotion 디스플레이 주사율(`CADisplayLink`)에 맞춘 터치 코얼레싱(`coalescedTouches`) 및 정적 터치 델타 압축(`DeltaCompressor`)
  - 시퀀스 번호(`frameIndex`) 기반 out-of-order / stale UDP 패킷 필터링
- **Wi-Fi & USB 유선 연결 모드 선택**
  - **iPad (`TrackpadClient`)**: `자동 (USB 우선)`, `Wi-Fi (무선)`, `USB 유선 연결` 선택 메뉴
  - **Mac (`TrackpadServer`)**: `모든 인터페이스 수신`, `USB 유선 전용`, `Wi-Fi 전용` 수신 인터페이스 필터
- **멀티터치 제스처 & macOS HID 이벤트 주입**
  - **1손가락**: 가속 곡선이 적용된 커서 이동, 탭하여 좌클릭 (더블/트리플 클릭 상태 지원)
  - **2손가락**: 120Hz 관성 스크롤(상하/좌우), 핀치 줌, 탭하여 우클릭
  - **3손가락**: Mission Control(위로 스와이프), App Exposé(아래로 스와이프), 스페이스/데스크톱 전환(좌우 스와이프) — 또는 메뉴바 옵션 전환 시 **3손가락 드래그**
  - **4손가락**: 3손가락 드래그 활성화 시 시스템 제스처 fallback
- **OLED 번인 방지 및 실시간 텔레메트리**
  - 순수 `#000000` 풀스크린 캔버스, HUD 자동 숨김, 햅틱 피드백
  - 양쪽 UI에서 RTT / 단방향 지연시간 / FPS(Hz) / PPS / 델타 압축 절감률 / DROP / 대역폭 실시간 표시

---

## 프로젝트 구성

```text
iPadTrackpad/
├── project.yml                         # XcodeGen 설정 (iPadOS 17+, macOS 14+, Swift 6.0)
├── iPadTrackpad.xcworkspace            # Xcode 워크스페이스
├── iPadTrackpad.xcodeproj              # 생성된 Xcode 프로젝트
├── SharedKit/                          # 공유 Swift Package (네트워크/프로토콜/제스처 엔진)
│   ├── Package.swift
│   ├── Sources/SharedKit/
│   │   ├── PacketProtocol.swift        # 바이너리 패킷 구조체 및 코덱 ("TP", _virtualtrackpad._tcp)
│   │   ├── DeltaCompressor.swift       # 정적 터치 억제, 델타 압축 및 키프레임 복원
│   │   ├── GestureEngine.swift         # 멀티터치 제스처 상태 머신 & 팜 리젝션
│   │   └── NetworkTransport.swift      # Bonjour 탐색/광고, TCP+UDP 듀얼 스트림, RTT 핑
│   └── Tests/SharedKitTests/
│       └── SharedKitTests.swift        # 패킷 라운드트립, 압축, 제스처 엔진 단위 테스트
├── TrackpadClient/                     # iPadOS 앱 (com.ipadtrackpad.client)
│   ├── Info.plist
│   └── Sources/
│       ├── TrackpadClientApp.swift
│       ├── ContentView.swift           # 풀스크린 트랙패드 UI, 연결 모드 메뉴, 설정 시트
│       ├── ClientSessionManager.swift  # 세션 상태, UDP/TCP 전송, 텔레메트리 관리
│       └── TrackpadTouchView.swift     # UIView 멀티터치 캡처, CADisplayLink, 3손가락 판별
└── TrackpadServer/                     # macOS 메뉴바 앱 (com.ipadtrackpad.server, LSUIElement)
    ├── Info.plist
    ├── TrackpadServer.entitlements
    └── Sources/
        ├── TrackpadServerApp.swift
        ├── MenuBarView.swift           # 메뉴바 상태창, 인터페이스 선택, 감도/제스처 설정
        ├── ServerManager.swift         # 리스너 수명주기, 수신 패킷 디코딩 및 상태 관리
        ├── AccessibilityHelper.swift   # 손쉬운 사용(Accessibility) 권한 확인 및 요청
        └── SyntheticEventDriver.swift  # CGEvent 커서/클릭/관성 스크롤/시스템 단축키 주입
```

---

## 요구 사항

- **macOS**: 14.0 이상 (`TrackpadServer`)
- **iPadOS**: 17.0 이상 (`TrackpadClient`, iPad 전용 타깃)
- **개발 환경**: Xcode (Swift 6.0, Strict Concurrency `complete`)

---

## 빌드 및 실행 방법

### 1. 서명(Signing) 팀 설정
[project.yml](project.yml) 또는 Xcode 프로젝트의 Signing & Capabilities에서 `TrackpadClient`와 `TrackpadServer` 타깃의 `Development Team`을 본인 Apple 개발자 계정/팀으로 변경하세요.

`project.yml`을 수정한 경우 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 프로젝트를 재생성할 수 있습니다.

```bash
xcodegen generate
```

### 2. 단위 테스트 (`SharedKit`)

```bash
cd SharedKit
swift test
```

### 3. Xcode 또는 CLI로 빌드

`iPadTrackpad.xcworkspace`를 Xcode에서 열어 각각 Mac / iPad 대상으로 실행하거나, CLI로 빌드할 수 있습니다.

```bash
# macOS 메뉴바 서버 빌드
xcodebuild -workspace iPadTrackpad.xcworkspace -scheme TrackpadServer -destination 'platform=macOS' -allowProvisioningUpdates build

# 연결된 iPad 실기기용 클라이언트 빌드 (<IPAD_UDID> 치환)
xcodebuild -workspace iPadTrackpad.xcworkspace -scheme TrackpadClient -destination 'id=<IPAD_UDID>' -allowProvisioningUpdates build
```

---

## 권한 및 초기 설정

1. **macOS 손쉬운 사용(Accessibility) 권한**
   - `TrackpadServer`는 `CGEvent`를 통해 커서, 스크롤, 키보드 단축키를 주입합니다.
   - 첫 실행 시 **시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용**에서 `TrackpadServer`를 허용해 주세요. (재빌드/재서명 후 권한이 동작하지 않으면 목록에서 제거 후 다시 추가하세요.)
2. **로컬 네트워크(Local Network) 권한**
   - Bonjour(`_virtualtrackpad._tcp`) 탐색 및 연결을 위해 iPadOS와 macOS에서 로컬 네트워크 접근 허용 팝업을 수락해 주세요.

---

## 지원 제스처 요약

| 제스처 | 동작 | 비고 |
| --- | --- | --- |
| 1손가락 이동 | 커서 이동 | macOS 가속 곡선 적용 |
| 1손가락 탭 | 좌클릭 | 더블/트리플 클릭 지원 |
| 2손가락 드래그 | 스크롤 (상하/좌우) | 120Hz 관성 스크롤 & 자연스러운 스크롤 토글 |
| 2손가락 핀치 | 확대 / 축소 | — |
| 2손가락 탭 | 우클릭 | — |
| 3손가락 스와이프 (상/하) | Mission Control / App Exposé | 메뉴바에서 **3손가락 드래그** 모드로 전환 가능 |
| 3손가락 스와이프 (좌/우) | 이전 / 다음 데스크톱(스페이스) | macOS Natural 트랙패드 방향 기준 |
| 4손가락 스와이프 | 시스템 제스처 fallback | 3손가락 드래그 활성화 시 사용 |
