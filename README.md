# multi-dev-ctrl

macOS 메뉴바에서 프로젝트별 개발 환경을 원클릭으로 실행하는 도구입니다.

## 기능
- 메뉴바에서 프로젝트 이름 클릭으로 사전 정의된 액션 일괄 실행
- 그룹별 프로젝트 비활성화(아카이브) 및 별도 복구 UI
- `runCommand`: 백그라운드에서 개발 서버 실행 (예: `npm run dev`)
- `openIterm`: iTerm 탭/창 열기 (선택적으로 명령 실행)
- `openItermSplit`: iTerm 한 탭을 2분할로 열고 명령 2개 동시 실행
- `openApp`: 앱 실행 (예: `Visual Studio Code`)
- 실행 중인 백그라운드 프로세스 정지

## 빠른 시작
1. 빌드
```bash
swift build
```

2. 사용자 설정 파일 생성
```bash
mkdir -p ~/.multi-dev-ctrl
cp config/projects.example.json ~/.multi-dev-ctrl/projects.json
```

3. `~/.multi-dev-ctrl/projects.json`의 프로젝트 경로/명령 수정

4. 실행
```bash
swift run
```

## 설정 파일 스키마
```json
{
  "projects": [
    {
      "name": "sample-web",
      "path": "/Users/you/Documents/sample-web",
      "projectType": "client",
      "isEnabled": true,
      "actions": [
        {
          "type": "openItermSplit",
          "commands": ["npm run dev", "npm run electron:dev"]
        }
      ]
    },
    {
      "name": "sample-api",
      "path": "/Users/you/Documents/sample-api",
      "projectType": "server",
      "port": 8080,
      "isEnabled": true,
      "actions": [
        {
          "type": "runCommand",
          "command": "./gradlew bootRun"
        }
      ]
    }
  ]
}
```

## How To Add A Project (EN)
1. Open `~/.multi-dev-ctrl/projects.json`.
2. Add one object to the `projects` array.
3. Set:
   - `name`: menu label
   - `path`: absolute project path
   - `projectType`: `client` or `server`
   - `port`: required for `server`, ignored for `client`
   - `isEnabled`: whether the project can be launched (`true` by default)
   - `actions`: what to run when clicked
4. Save the file, then click `Reload Config` in the menu bar app.

Example:
```json
{
  "projects": [
    {
      "name": "sample-web",
      "path": "/Users/you/Documents/sample-web",
      "projectType": "client",
      "isEnabled": true,
      "actions": [
        {
          "type": "openItermSplit",
          "commands": ["npm run dev", "npm run electron:dev"]
        }
      ]
    },
    {
      "name": "sample-ads",
      "path": "/Users/you/Documents/sample-ads",
      "projectType": "server",
      "port": 8080,
      "actions": [
        {
          "type": "openIterm",
          "command": "./mvnw spring-boot:run"
        }
      ]
    }
  ]
}
```

## 프로젝트 추가 방법 (KO)
1. `~/.multi-dev-ctrl/projects.json` 파일을 엽니다.
2. `projects` 배열에 프로젝트 객체를 하나 추가합니다.
3. 아래 값을 설정합니다.
   - `name`: 메뉴바에 보일 이름
   - `path`: 프로젝트 절대 경로
   - `projectType`: `client` 또는 `server`
   - `port`: `server`일 때 필수, `client`일 때는 무시
   - `isEnabled`: 실행 가능 여부 (`true` 기본값)
   - `actions`: 클릭 시 실행할 동작 목록
4. 저장 후 메뉴바 앱에서 `Reload Config`를 누릅니다.

예시:
```json
{
  "projects": [
    {
      "name": "sample-web",
      "path": "/Users/you/Documents/sample-web",
      "projectType": "client",
      "isEnabled": true,
      "actions": [
        {
          "type": "openItermSplit",
          "commands": ["npm run dev", "npm run electron:dev"]
        }
      ]
    },
    {
      "name": "sample-ads",
      "path": "/Users/you/Documents/sample-ads",
      "projectType": "server",
      "port": 8080,
      "actions": [
        {
          "type": "openIterm",
          "command": "./mvnw spring-boot:run"
        }
      ]
    }
  ]
}
```

### action type
- `runCommand`
  - 필수: `command`
  - 지정 경로에서 `zsh -lc`로 실행됩니다.
- `openIterm`
  - 선택: `command`
  - `command`가 있으면 iTerm 새 탭에서 `cd <path>; <command>` 실행
  - `command`가 없으면 해당 경로로 iTerm 열기
- `openItermSplit`
  - 필수: `commands` (최소 2개)
  - iTerm 한 탭에서 세로 스플릿으로 명령 2개를 동시에 실행
- `openApp`
  - 필수: `appName`
  - `open -a <appName>` 형태로 실행

### 프로젝트 활성/비활성
- `isEnabled`가 없으면 기본값은 `true`입니다.
- `isEnabled: false`인 프로젝트는 메인 메뉴 목록에 표시되지 않습니다.
- `전체 실행`, 그룹 실행, 전체 커밋/푸시 대상에서도 제외됩니다.
- 메인 화면에서는 그룹 단위로만 비활성화할 수 있습니다.
- 비활성 프로젝트는 `비활성 프로젝트 관리` UI에서 개별 또는 그룹 단위로 복구할 수 있습니다.

## 로그
- 백그라운드 명령 로그: `~/.multi-dev-ctrl/logs/<project>.log`

## 앱 설치

빌드 후 `/Applications`에 .app 번들로 설치합니다.

```bash
make install
```

설치 후 실행:
```bash
open /Applications/MultiDevCtrl.app
```

로그인 시 자동 실행: **시스템 설정 > 일반 > 로그인 항목**에서 MultiDevCtrl 추가

삭제:
```bash
make uninstall
```

## 프로젝트 그룹핑

`group` 필드로 프로젝트를 그룹별로 묶어서 메뉴에 표시할 수 있습니다. `group`이 없으면 "기타"로 분류됩니다.

```json
{
  "projects": [
    { "name": "my-web", "group": "dropstudio", "path": "...", "actions": [...] },
    { "name": "my-admin", "group": "dropstudio", "path": "...", "actions": [...] },
    { "name": "other-app", "path": "...", "actions": [...] }
  ]
}
```

## iTerm 모드 설정

메뉴 하단의 **iTerm 모드** 서브메뉴에서 전환하거나, `projects.json`에서 직접 설정할 수 있습니다.

| 모드 | 설명 |
|------|------|
| `window` | 프로젝트마다 새 iTerm 윈도우 (기본값) |
| `tab` | 하나의 iTerm 윈도우에 탭으로 열기 |

```json
{
  "itermMode": "tab",
  "projects": [...]
}
```

## 포트 자동 설정

포트는 프로젝트 실행 시점에 결정됩니다.

- `client` 프로젝트는 실행 시 사용 가능한 포트를 자동 배정합니다.
- `server` 프로젝트는 추가/수정 시 입력한 `port`를 고정 사용합니다.
- `server`의 고정 포트가 이미 사용 중이면 다른 포트로 재배정하지 않고 실행을 중단합니다.
- 메뉴에는 실행 중 실제 사용 포트가 표시됩니다.

## 메뉴 구조

```
── 그룹명 ──
🟢 project-name :3000 ✗  ▸  실행 / 코드 / 커밋&푸시 / 중지
○  project-name            ▸  실행 / 코드 / 커밋&푸시
──────────────
▶  전체 실행
■  전체 중지
전체 커밋 및 푸시
──────────────
설정 새로고침
설정 폴더 열기
iTerm 모드: 탭/윈도우  ▸
──────────────
종료
```

| 아이콘 | 의미 |
|--------|------|
| 🟢 | 실행 중 (포트 리슨 감지) |
| ○ | 미실행 |
| ✗ | Git 변경사항 있음 |
| (없음) | Git 최신 상태 |

## 참고
- iTerm 제어는 macOS 자동화 권한 허용이 필요할 수 있습니다.
- 설정 파일 탐색 순서:
  1. `~/.multi-dev-ctrl/projects.json`
  2. `<현재 실행 경로>/config/projects.json`
