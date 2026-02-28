# multi-dev-ctrl

macOS 메뉴바에서 프로젝트별 개발 환경을 원클릭으로 실행하는 도구입니다.

## 기능
- 메뉴바에서 프로젝트 이름 클릭으로 사전 정의된 액션 일괄 실행
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
      "actions": [
        {
          "type": "openItermSplit",
          "commands": ["npm run dev", "npm run electron:dev"]
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
   - `actions`: what to run when clicked
4. Save the file, then click `Reload Config` in the menu bar app.

Example:
```json
{
  "projects": [
    {
      "name": "sample-web",
      "path": "/Users/you/Documents/sample-web",
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
      "actions": [
        {
          "type": "openIterm",
          "command": "npm run electron:dev"
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
   - `actions`: 클릭 시 실행할 동작 목록
4. 저장 후 메뉴바 앱에서 `Reload Config`를 누릅니다.

예시:
```json
{
  "projects": [
    {
      "name": "sample-web",
      "path": "/Users/you/Documents/sample-web",
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
      "actions": [
        {
          "type": "openIterm",
          "command": "npm run electron:dev"
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

## 로그
- 백그라운드 명령 로그: `~/.multi-dev-ctrl/logs/<project>.log`

## 참고
- iTerm 제어는 macOS 자동화 권한 허용이 필요할 수 있습니다.
- 설정 파일 탐색 순서:
  1. `~/.multi-dev-ctrl/projects.json`
  2. `<현재 실행 경로>/config/projects.json`
