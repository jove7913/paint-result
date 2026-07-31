# 도장 실적 앱 · Resultado de pintura

NKU 도장 라인 실적 입력 및 실시간 현황 시스템.
휴대폰·PC·TV 어디서나 브라우저로 접속하고, 휴대폰에는 앱처럼 설치된다.

## 파일 구성

| 파일 | 용도 |
|---|---|
| `index.html` | 본 앱 (Supabase 연결) |
| `sw.js` | 서비스 워커 — 앱 화면 캐시, 설치 지원 |
| `manifest.webmanifest` | 앱 이름·아이콘·시작 주소 정의 |
| `icon-*.png`, `apple-touch-icon.png` | 홈 화면 아이콘 |
| `schema.sql` | Supabase DB 스키마 (최초 1회 실행) |
| `demo.html` | 백엔드 없이 화면만 보는 목업 |

---

## 1. Supabase 준비

1. **SQL Editor** 에 `schema.sql` 전체를 붙여넣고 Run
2. **Settings → API → Exposed schemas** 에 `paint` 추가 후 저장
3. **Authentication → Providers → Email** 활성화, *Confirm email* 은 끔
4. **Settings → API** 에서 `Project URL` 과 `anon public` 키 복사

## 2. 키 입력

`index.html` 상단 두 줄을 교체한다.

```js
const SUPABASE_URL = "https://xxxx.supabase.co";
const SUPABASE_KEY = "eyJhbGci...";
```

## 3. GitHub Pages 배포

```bash
git init
git add .
git commit -m "도장 실적 앱 최초 배포"
git branch -M main
git remote add origin https://github.com/jove7913/paint-result.git
git push -u origin main
```

리포는 **Public** 으로 생성한다.
**Settings → Pages → Source: `main` / `/ (root)`** 저장 후 1~2분 대기.

주소: `https://jove7913.github.io/paint-result/`

> 서비스 워커와 앱 설치는 HTTPS에서만 동작한다. GitHub Pages는 기본이 HTTPS라 그대로 된다.

## 4. 최초 관리자 지정

앱에서 본인 사번·이름·PIN으로 **회원가입** 후, SQL Editor에서 한 줄 실행.

```sql
update paint.workers set approved = true, role = 'admin' where emp_no = '본인사번';
```

이후 모든 승인은 앱의 **작업자** 탭에서 처리한다.

## 5. 기기별 설치

**안드로이드 (Chrome)**
주소 접속 → 로그인 화면의 `홈 화면에 설치` 버튼, 또는 브라우저 메뉴 → 앱 설치

**아이폰 (Safari)**
주소 접속 → 공유 버튼 → `홈 화면에 추가`
(iOS는 설치 버튼이 뜨지 않으므로 이 방법만 가능)

**PC**
Chrome·Edge 주소창 오른쪽 설치 아이콘

**TV / 현황판**
`https://jove7913.github.io/paint-result/#tv` 를 즐겨찾기로 등록.
관리자 계정으로 한 번 로그인해두면 이후 자동으로 6분할 화면이 뜬다.
1분마다 자동 갱신되고, 실적이 저장되면 즉시 반영된다.

---

## 화면 업데이트 방법

`index.html` 을 고쳐 push하면 끝이다. 화면은 네트워크 우선으로 불러오므로
사용자가 앱을 다시 열면 새 버전이 적용된다.
아이콘이나 `manifest` 를 바꿨다면 `sw.js` 의 `VERSION` 값을 올려야 기기 캐시가 갱신된다.

```js
const VERSION = "v2";   // v1 → v2
```

## 알아둘 점

- 계획은 **당일(work_date) 기준**으로만 조회된다. 매일 아침 계획을 올리는 운용을 전제로 한다.
- 오프라인에서는 앱이 열리기는 하나 실적 조회·저장은 되지 않는다. 저장 실패 시 화면에 오류가 뜨므로 연결 복구 후 다시 저장해야 한다.
- PIN 4자리는 내부적으로 확장해 비밀번호로 쓰지만 강도는 낮다. 인사·급여 정보가 붙는다면 자릿수를 늘려야 한다.
- `anon public` 키는 공개되어도 무방하다. 접근 통제는 전적으로 DB의 RLS 정책이 담당한다.

---

## 주요 기능 요약

**작업자 (휴대폰)**
- 첫 화면에서 일자·근무조를 자동 판별해 표시 (주간 07:30~19:30 / 야간 19:30~다음날 07:30)
  · 새벽 접속 시 전날 야간조 계획을 연다. 날짜·주야는 직접 바꿔볼 수도 있다
- 라인 선택 → 계획 목록 → [투입시작] 버튼으로 시작 시각 기록
- 품번을 눌러 투입수량·OK·NG·코멘트 입력, 직행율 자동 계산
- OK 수량이 들어가면 상태가 생산종료로 전환
- 계획에 없는 품번도 검색해 추가 입력 가능

**관리자**
- 계획: 날짜·근무조별로 미리 등록, 개별 수정·삭제, CSV 일괄등록
- 마스터: 차종·품번·품명·컬러·도장사양, CSV 일괄등록, 개별 삭제
- 작업자: 가입 승인, 관리자 지정, 차단·삭제
- 현황: 전체 / 라인별, 투입중·생산종료·대기 필터

**TV 현황판**
- 주소 끝에 `#tv` → 6분할 (1~5라인 + 전체 진도율)
- `순환` 버튼으로 한 화면씩 10초 간격 전체화면 전환
- `밝게 / 어둡게` 전환, 1분마다 자동 갱신, 실적 저장 시 즉시 반영

## CSV 양식

**마스터** — 차종 / 품번 / 품명 / 컬러 / 도장사양
**계획** — 일자 / 근무조 / 라인 / 품번 / 계획수량
(일자는 `2026-08-05`, 근무조는 `주`·`야`·`A`·`B` 모두 인식)

엑셀 저장 시 반드시 **CSV UTF-8(쉼표로 분리)** 형식을 고를 것.
