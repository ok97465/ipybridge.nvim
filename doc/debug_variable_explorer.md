# 디버그 모드 Variable Explorer 동작 개요

## 전체 흐름
1. `debugfile()`이 실행되어 IPython 디버거가 활성화되면 `exec_magics.py` 안의 `_mi_emit_vars_snapshot()`이 호출됩니다.
2. 이 함수는 `bootstrap_helpers.py`의 `_myipy_emit_debug_vars()`를 우선적으로 사용해 현재 프레임의 변수 정보를 수집합니다.
3. `_myipy_emit_debug_vars()`는 `ipybridge_ns` 모듈의 도우미들로 네임스페이스를 모으고, 변수 목록과 요약 정보를 계산합니다.
4. 계산된 결과는 OSC 시퀀스로 암호화되어 터미널로 전달되고, Neovim 쪽 `term_ipy.lua`가 이를 수신하여 `dispatch.lua`에 전달합니다.
5. `dispatch.lua`는 `ipybridge.var_explorer`의 `on_vars()`를 호출하고, 여기서 최신 변수 목록이 갱신됩니다.
6. `init.lua`의 `M._digest_vars_snapshot()`이 로컬/글로벌 스냅샷을 갱신하고, 스코프 선택에 재사용합니다.

## 디버그 프리뷰 처리
- `bootstrap_helpers.py`
  - `_PREVIEW_LIMITS`에 현재 설정된 행·열 제한을 보관합니다.
  - `_myipy_emit_debug_vars()`는 현재 프레임의 로컬·글로벌 네임스페이스를 분리해 스냅샷을 만들고, `_DebugPreviewContext.capture()`로 최신 네임스페이스와 프리뷰 한계를 기록합니다.
  - `_DebugPreviewServer.ensure_running()`는 모듈 로드 시 127.0.0.1에 소켓 서버를 열고, 전용 스레드에서 `_DebugPreviewContext.compute()`를 호출해 온디맨드 프리뷰를 제공합니다.
  - `__mi_debug_preview()`와 `__mi_debug_server_info()`는 각각 JSON 응답으로 프리뷰/서버 포트를 반환하며, 백엔드가 부하 없이 상태를 확인할 수 있습니다.

## Neovim 쪽 처리
- `lua/ipybridge/init.lua`
  - `_digest_vars_snapshot()`이 로컬·글로벌 스냅샷을 별도로 저장하고, `on_debug_location()`에서 받은 함수 정보(`info.function`)로 “현재는 로컬/글로벌” 상태를 판단합니다.
  - `M._latest_vars`는 현재 보여줄 스코프(함수 내부라면 로컬, 아니면 글로벌)를 골라낸 사본만 유지합니다.
  - `lua/ipybridge/debug/scope.lua` 모듈이 전역 스냅샷이 비어 있어도 로컬 값을 안전하게 반환하도록 우선순위를 처리하며, `M._latest_vars` 갱신 시 재사용합니다.
- `lua/ipybridge/controllers/variables.lua`
  - 디버그 모드에서는 프리뷰 요청을 항상 ZMQ 백엔드로 전달하며, `debug = true` 요청이 소켓 서버를 통해 온디맨드 프리뷰를 반환합니다.
- `lua/ipybridge/dispatch.lua`
  - Python에서 넘어온 스냅샷을 `M._digest_vars_snapshot()`에 먼저 통과시켜 로컬/글로벌 상태를 갱신하고, 변수 탐색기에는 화면에 필요한 데이터만 전달합니다.
- `lua/ipybridge/data_viewer.lua`
  - ctypes/데이터클래스 미리보기에서 드릴다운이 가능한 항목(`map`)을 `이름.필드` 형태로 만들어 추가 프리뷰 요청을 보냅니다.

## 현재 동작 특징
- 디버그 프리뷰는 항상 온디맨드로 계산됩니다. 디버거 스텝 시점에는 변수 목록만 전송되고, 프리뷰 요청 시에만 커널 연산이 발생합니다.
- ndarray/DataFrame 뷰어에서는 `<C-f>`/`<C-b>`로 행 페이지를, `<C-l>`/`<C-h>`(또는 `<C-Right>`/`<C-Left>`)로 열 페이지를 이동하며 요청한 범위만큼 커널에서 데이터를 다시 받아옵니다.
- 새로운 타입에 대한 프리뷰를 추가할 때는 `ipybridge_ns.preview_data()`만 확장하면 온디맨드 경로에 반영됩니다.

## 주의 사항
- 프리뷰는 현재 프레임에서 해석 가능한 객체만 다룹니다. 디버거가 프레임을 이동하면 새로 스냅샷을 받아야 합니다.
- 대용량 객체나 DataFrame 열처럼 키 수가 많은 경우 프리뷰 비용이 커질 수 있으니 `viewer_max_rows`, `viewer_max_cols`를 적절히 조절해 주는 것이 좋습니다.

## 로깅 체크 포인트
- `_DebugPreviewContext.capture()`가 실행되면 `_ipy_log_debug`에 `debug context stored ...` 메시지가 남습니다. 프레임 이동 시 컨텍스트가 정상적으로 갱신됐는지 확인할 수 있습니다.
- `_DebugPreviewContext.compute()`가 호출되면 `debug preview compute name=... status=...` 로그가 추가로 남습니다. 소켓 서버가 제어 프롬프트를 중단시키지 않고 호출되는지 추적할 때 사용합니다.
- 소켓 서버는 시작 시 `debug preview server listening port=...` 로그를, 예외 발생 시 `debug preview server ...` 로그를 남깁니다.
