const app = document.querySelector('#app');
const params = new URLSearchParams(location.search);
const view = params.get('view') || 'home';

const syntheticNotice = `<div class="status-strip"><div class="status-strip-inner"><span class="status-dot"></span><strong>합성 디자인 데이터</strong><span>이 화면의 기관·업체·계약은 실제 대상이 아닙니다.</span></div></div>`;
const header = () => document.querySelector('#public-header').content.cloneNode(true);
const footer = `<footer class="footer"><div class="footer-inner"><div><strong>구린네</strong> · 공공계약 이상 징후 조사 플랫폼</div><div>방법론 · 데이터 범위 · 편집 정책 · 정정 · 개인정보</div></div></footer>`;

const home = `
<div class="shell">${syntheticNotice}<div id="header-slot"></div>
<main id="main" class="main">
  <section class="hero">
    <div>
      <div class="eyebrow">공개자료를 근거로, 설명이 필요한 차이를 찾습니다</div>
      <h1>공공의 돈을<br>근거로 읽는 법</h1>
      <p class="lead hero-copy">구린네는 계약·예산 공개자료에서 조사할 가치가 있는 이상 징후를 찾고, 확인된 사실과 중요한 미확인, 당사자 소명, 원본 근거를 함께 보여줍니다.</p>
      <div class="hero-note"><span aria-hidden="true">ⓘ</span><div><strong>자동 부패 판정기가 아닙니다.</strong><br><span class="small">가격 차이나 반복 계약은 조사 신호일 뿐이며 위법·비리를 의미하지 않습니다.</span></div></div>
      <form class="search-box" role="search"><input aria-label="통합 검색" placeholder="기관, 업체, 계약번호, 공개 기록 검색"><button class="primary-button" type="button">검색</button></form>
    </div>
    <aside class="hero-board" aria-label="최근 공개 기록">
      <div class="board-label">최근 공개·설명·정정 기록</div>
      <div class="board-record"><strong>가상새빛시청 안전장비 구매의 단가 비교</strong><div class="board-meta"><span class="board-state">이상 징후 공개</span><span>소명 포함</span><span>revision 3</span></div></div>
      <div class="board-record"><strong>가상한결공사의 유지보수 묶음 비용</strong><div class="board-meta"><span class="board-state">설명 확인</span><span>묶음 구성 확인</span><span>revision 2</span></div></div>
      <div class="board-record"><strong>가상푸른군 계약 수량 표기 오류 정정</strong><div class="board-meta"><span style="color:#efb5b5">정정</span><span>원 자료 단위 수정</span><span>revision 4</span></div></div>
    </aside>
  </section>
  <section class="metrics-row" aria-label="데이터 범위 요약">
    <div class="metric"><div class="metric-value">6</div><div class="metric-label">연결된 공개 source</div></div>
    <div class="metric"><div class="metric-value">2021–현재</div><div class="metric-label">수집 범위</div></div>
    <div class="metric"><div class="metric-value">2시간 전</div><div class="metric-label">최근 성공 수집</div></div>
    <div class="metric"><div class="metric-value">1개</div><div class="metric-label">현재 알려진 지연 source</div></div>
  </section>
  <section class="section">
    <div class="section-head"><div><div class="eyebrow">공개 기록</div><h2>결론보다 상태와 근거를 먼저 봅니다</h2></div><p>이상 징후, 설명 완료, 정정과 철회를 같은 위계에서 보여주며 “가장 구린” 순위를 만들지 않습니다.</p></div>
    <div class="record-grid">
      <article class="record-card"><div class="badges"><span class="badge info">이상 징후 공개</span><span class="badge neutral">소명 수록</span></div><h3>가상새빛시청 안전장비 구매 단가 비교</h3><p>동일 범주 12건의 중앙값보다 단가가 높게 관측됐습니다. 인증·설치 비용 포함 여부가 핵심 미확인입니다.</p><div class="record-footer"><span>2026.07.09 갱신</span><a href="?view=case">근거 보기 →</a></div></article>
      <article class="record-card"><div class="badges"><span class="badge verified">설명 확인</span></div><h3>가상한결공사 유지보수 계약</h3><p>장비 단가 차이는 3년 유지보수와 현장 교육이 포함된 묶음 계약으로 확인됐습니다.</p><div class="record-footer"><span>2026.07.08 갱신</span><a href="#">설명 보기 →</a></div></article>
      <article class="record-card"><div class="badges"><span class="badge correction">정정</span></div><h3>가상푸른군 계약 수량 표기</h3><p>원 공개자료의 수량 단위를 SET에서 EA로 잘못 정규화한 오류를 정정하고 계산을 철회했습니다.</p><div class="record-footer"><span>2026.07.07 정정</span><a href="#">정정 이력 →</a></div></article>
    </div>
  </section>
  <section class="section">
    <div class="section-head"><div><div class="eyebrow">작동 방식</div><h2>원본에서 공개 문장까지 끊기지 않게</h2></div></div>
    <div class="record-grid">
      <article class="record-card"><span class="evidence-index">1</span><h3 style="margin-top:18px">수집·정규화</h3><p>원본 byte, hash, parser와 field provenance를 보존합니다.</p></article>
      <article class="record-card"><span class="evidence-index">2</span><h3 style="margin-top:18px">결정적 탐지·조사</h3><p>비교 조건을 통과한 신호만 만들고 반대 가설과 데이터 blocker를 조사합니다.</p></article>
      <article class="record-card"><span class="evidence-index">3</span><h3 style="margin-top:18px">사람 검토·공개</h3><p>소명권과 독립 검토를 거친 revision만 공개하고 정정 이력을 지우지 않습니다.</p></article>
    </div>
  </section>
</main>${footer}</div>`;

const caseView = `
<div class="shell">${syntheticNotice}<div id="header-slot"></div>
<main id="main" class="main">
  <nav class="breadcrumb"><a href="?view=home">홈</a><span>›</span><a href="?view=search">공개 사례</a><span>›</span><span>가상 사례 2026-014</span></nav>
  <header class="case-header">
    <div class="case-meta"><span class="badge info">이상 징후 공개</span><span class="badge neutral">소명 포함</span><span class="small muted">revision 3</span><span class="small muted">2026.07.09 갱신</span></div>
    <h1 class="case-title">가상새빛시청 안전장비 구매의 단가 비교</h1>
    <p class="lead case-summary">비교 가능한 12건의 중앙값보다 대상 계약 단가가 높게 관측됐습니다. 현재 공개자료만으로 위법성이나 부패 여부를 판단할 수 없으며, 인증·설치 비용 포함 여부가 결과를 바꿀 수 있는 핵심 미확인입니다.</p>
  </header>
  <div class="case-layout">
    <div class="case-main">
      <section aria-labelledby="current-understanding"><div class="eyebrow">현재 판단에 필요한 핵심</div><h2 id="current-understanding">확인·미확인·소명을 분리해서 봅니다</h2>
        <div class="triad">
          <article class="triad-box known"><h3>확인된 사실</h3><ul><li>계약서상 수량은 20 EA입니다.</li><li>표시 단가는 2,400,000원입니다.</li><li>동일 단위 비교군은 12건입니다.</li></ul></article>
          <article class="triad-box unknown"><h3>중요한 미확인</h3><ul><li>특수 인증 비용의 포함 범위</li><li>현장 설치·교육의 별도 여부</li><li>모델 세대의 완전한 동일성</li></ul></article>
          <article class="triad-box response"><h3>당사자 소명</h3><p class="small">“계약 금액에는 현장 적합성 시험과 2년간 부품 보증이 포함되어 있습니다.”</p><a class="small" href="#response">전체 소명과 첨부 근거</a></article>
        </div>
      </section>
      <section id="response"><div class="eyebrow">당사자 소명</div><h2>가상새빛시청의 답변</h2><blockquote class="response-quote">표시된 장비는 일반 판매 모델과 외형은 같지만 현장 적합성 시험, 추가 내충격 인증, 납품 후 교육과 2년 부품 보증을 포함합니다.</blockquote><p class="small muted">2026.07.05 제출 · 공개 동의 범위: 답변 본문과 첨부 2건 · 편집 검증 완료</p></section>
      <section><div class="eyebrow">비교와 계산</div><h2>대상 단가는 비교 중앙값의 5.0배입니다</h2><p>다만 배수는 비리 확률이 아닙니다. 단위, VAT, 구매 시점, 묶음 구성과 인증 조건이 확인된 계약만 포함했습니다.</p>
        <div class="comparison-summary">
          <div class="ratio"><strong>5.0×</strong><span>2,400,000 ÷ 480,000</span></div>
          <div class="bar-chart" aria-label="단가 비교">
            <div class="bar-row"><span>비교 하위</span><div class="bar-track"><div class="bar-fill" style="width:14%"></div></div><strong>340,000</strong></div>
            <div class="bar-row"><span>중앙값</span><div class="bar-track"><div class="bar-fill" style="width:20%"></div></div><strong>480,000</strong></div>
            <div class="bar-row"><span>비교 상위</span><div class="bar-track"><div class="bar-fill" style="width:31%"></div></div><strong>740,000</strong></div>
            <div class="bar-row"><span>대상 계약</span><div class="bar-track"><div class="bar-fill target" style="width:100%"></div></div><strong>2,400,000</strong></div>
          </div>
        </div>
        <table class="data-table"><caption>대표 비교 기록 — 전체 12건은 계산 재현 화면에서 확인할 수 있습니다.</caption><thead><tr><th>기관</th><th>시점</th><th>단위</th><th>포함 조건</th><th>단가</th></tr></thead><tbody>
          <tr class="target"><td data-label="기관">가상새빛시청</td><td data-label="시점">2026.03</td><td data-label="단위">EA</td><td data-label="포함 조건">인증·보증 주장, 세부 미확인</td><td data-label="단가"><strong>2,400,000원</strong></td></tr>
          <tr><td data-label="기관">가상한빛도청</td><td data-label="시점">2026.02</td><td data-label="단위">EA</td><td data-label="포함 조건">배송 포함</td><td data-label="단가">470,000원</td></tr>
          <tr><td data-label="기관">가상푸른공사</td><td data-label="시점">2025.12</td><td data-label="단위">EA</td><td data-label="포함 조건">배송 포함</td><td data-label="단가">490,000원</td></tr>
        </tbody></table>
      </section>
      <section><div class="eyebrow">반대 근거와 대안 설명</div><h2>가격 차이가 합리적일 수 있는 조건</h2><div class="context-box"><ul class="context-list"><li>추가 인증 시험 비용이 실제 납품 범위에 포함됐다면 비교 가능성이 낮아집니다.</li><li>2년 부품 보증의 시장 가치가 확인되면 유효 비교 금액을 조정해야 합니다.</li><li>비교군의 모델 세대가 다르면 cohort를 다시 구성해야 합니다.</li></ul></div></section>
      <section><div class="eyebrow">증거와 provenance</div><h2>공개 문장을 원본까지 추적합니다</h2><div class="evidence-list">
        <article class="evidence-item"><div class="evidence-index">E1</div><div><div class="evidence-title">계약 공개 원문</div><div class="evidence-meta">계약번호 SYN-2026-014 · locator 3쪽 2행 · SHA-256 8c4a…91fe</div></div><button class="secondary-button">문맥 보기</button></article>
        <article class="evidence-item"><div class="evidence-index">E2</div><div><div class="evidence-title">비교군 계산 snapshot</div><div class="evidence-meta">PRICE_OUTLIER v1.0 · 입력 12건 · 제외 4건 · 결과 hash 1b2f…aa37</div></div><button class="secondary-button">재현하기</button></article>
        <article class="evidence-item"><div class="evidence-index">E3</div><div><div class="evidence-title">당사자 소명과 첨부</div><div class="evidence-meta">답변 2026.07.05 · 첨부 2건 · 공개 excerpt 검증 완료</div></div><button class="secondary-button">소명 보기</button></article>
      </div></section>
      <section><div class="eyebrow">Revision과 정정</div><h2>무엇이 바뀌었는지 숨기지 않습니다</h2><table class="data-table"><thead><tr><th>Revision</th><th>날짜</th><th>상태</th><th>주요 변경</th></tr></thead><tbody>
        <tr><td data-label="Revision">3 (현재)</td><td data-label="날짜">2026.07.09</td><td data-label="상태">소명 포함</td><td data-label="주요 변경">인증·보증 답변과 핵심 미확인 추가</td></tr>
        <tr><td data-label="Revision">2</td><td data-label="날짜">2026.07.02</td><td data-label="상태">공개</td><td data-label="주요 변경">비교군 10건에서 12건으로 재계산</td></tr>
        <tr><td data-label="Revision">1</td><td data-label="날짜">2026.06.28</td><td data-label="상태">최초 공개</td><td data-label="주요 변경">초기 조사 결과</td></tr>
      </tbody></table></section>
    </div>
    <aside class="case-aside" aria-label="사건 문맥">
      <div class="context-box"><h3>판단 상태</h3><p class="small"><strong>위법성 미확정</strong><br>공개자료 기반의 이상 징후입니다.</p><a class="small" href="#">상태 기준 보기</a></div>
      <div class="context-box"><h3>데이터 범위</h3><ul class="context-list"><li>계약 2025.01–2026.03</li><li>공식 source 2개</li><li>최근 성공 2시간 전</li></ul></div>
      <div class="context-box"><h3>바로가기</h3><ul class="context-list"><li><a href="#response">당사자 소명</a></li><li><a href="#">계산 재현</a></li><li><a href="#">정정 요청</a></li></ul></div>
    </aside>
  </div>
</main>${footer}</div>`;

const search = `
<div class="shell">${syntheticNotice}<div id="header-slot"></div><main id="main" class="main">
<nav class="breadcrumb"><a href="?view=home">홈</a><span>›</span><span>통합 검색</span></nav>
<div class="eyebrow">통합 검색</div><h1>공개 기록 찾기</h1><p class="lead">사건, 계약, 기관과 업체를 한 번에 찾습니다. 검색 결과의 상태는 의혹의 순위가 아닙니다.</p>
<form class="search-box" style="max-width:820px;margin:28px 0"><input value="가상새빛" aria-label="검색어"><button class="primary-button">검색</button></form>
<div class="case-layout">
<aside class="context-box" style="position:static"><h3>검색 범위</h3><div class="choice"><input type="checkbox" checked><span><strong>공개 사건</strong><br><span class="small muted">정정·설명 완료 포함</span></span></div><div class="choice"><input type="checkbox" checked><span><strong>계약</strong></span></div><div class="choice"><input type="checkbox" checked><span><strong>기관·업체</strong></span></div><h3 style="margin-top:22px">상태</h3><div class="badges"><span class="badge info">이상 징후 1</span><span class="badge verified">설명 1</span><span class="badge correction">정정 0</span></div></aside>
<section><div class="section-head"><div><h2>“가상새빛” 검색 결과</h2><p>총 4개 기록 · 2026.07.11 09:20 기준</p></div><select aria-label="정렬"><option>관련도순</option><option>최근 갱신순</option></select></div>
<div class="evidence-list">
<article class="evidence-item"><div class="evidence-index">사건</div><div><div class="badges"><span class="badge info">이상 징후 공개</span></div><div class="evidence-title"><a href="?view=case">가상새빛시청 안전장비 구매의 단가 비교</a></div><p class="small">확인된 사실 3 · 중요한 미확인 3 · 소명 있음</p></div></article>
<article class="evidence-item"><div class="evidence-index">기관</div><div><div class="evidence-title"><a href="?view=agency">가상새빛시청</a></div><p class="small">관측 계약 148건 · 공개 사건 2건 · 설명 완료 1건 · source 지연 없음</p></div></article>
<article class="evidence-item"><div class="evidence-index">계약</div><div><div class="evidence-title">SYN-2026-014 안전장비 구매</div><p class="small">가상새빛시청 → 가상알파안전 · 48,000,000원 · 2026.03.18</p></div></article>
</div></section></div></main>${footer}</div>`;

const agency = `
<div class="shell">${syntheticNotice}<div id="header-slot"></div><main id="main" class="main">
<nav class="breadcrumb"><a href="?view=home">홈</a><span>›</span><a href="?view=search">기관</a><span>›</span><span>가상새빛시청</span></nav>
<div class="case-header"><div class="case-meta"><span class="badge neutral">기초지방자치단체</span><span class="small muted">identity verified</span></div><h1>가상새빛시청</h1><p class="lead">이 페이지는 수집 범위 안의 계약과 공개 기록을 설명합니다. 기관의 청렴도나 부패 가능성을 점수화하지 않습니다.</p></div>
<section class="metrics-row"><div class="metric"><div class="metric-value">148</div><div class="metric-label">관측 계약 · 2025.01–현재</div></div><div class="metric"><div class="metric-value">₩12.8억</div><div class="metric-label">관측 계약금액</div></div><div class="metric"><div class="metric-value">2</div><div class="metric-label">공개 이상 징후</div></div><div class="metric"><div class="metric-value">1</div><div class="metric-label">설명 완료</div></div></section>
<div class="case-layout" style="margin-top:46px"><div class="case-main">
<section><div class="eyebrow">범위와 한계</div><h2>이 숫자가 포함하는 것</h2><div class="triad"><div class="triad-box known"><h3>포함</h3><ul><li>공식 계약정보</li><li>2025.01 이후</li><li>완료·취소 상태 구분</li></ul></div><div class="triad-box unknown"><h3>알려진 누락</h3><ul><li>일부 계약 부속 문서</li><li>2024년 이전 이력</li></ul></div><div class="triad-box response"><h3>최신성</h3><ul><li>최근 성공 2시간 전</li><li>예상 주기 2시간</li></ul></div></div></section>
<section><div class="eyebrow">상태별 공개 기록</div><h2>설명과 정정을 함께 봅니다</h2><div class="record-grid"><article class="record-card"><div class="badges"><span class="badge info">이상 징후 공개 2</span></div><p>현재 설명되지 않은 이상 징후 기록입니다.</p></article><article class="record-card"><div class="badges"><span class="badge verified">설명 확인 1</span></div><p>추가 자료로 합리적 차이가 확인된 기록입니다.</p></article><article class="record-card"><div class="badges"><span class="badge correction">정정·철회 0</span></div><p>현재 공개된 정정 또는 철회 기록은 없습니다.</p></article></div></section>
<section><div class="eyebrow">최근 계약</div><h2>원본과 정규화 경고를 함께 표시</h2><table class="data-table"><thead><tr><th>계약</th><th>업체</th><th>금액</th><th>방법</th><th>상태</th></tr></thead><tbody>
<tr><td data-label="계약">안전장비 구매</td><td data-label="업체">가상알파안전</td><td data-label="금액">48,000,000원</td><td data-label="방법">경쟁</td><td data-label="상태"><span class="badge info">사건 연결</span></td></tr>
<tr><td data-label="계약">청사 네트워크 유지보수</td><td data-label="업체">가상넷서비스</td><td data-label="금액">32,000,000원</td><td data-label="방법">수의</td><td data-label="상태"><span class="badge neutral">완료</span></td></tr>
</tbody></table></section></div>
<aside class="case-aside"><div class="context-box"><h3>식별자</h3><ul class="context-list"><li>기관코드 SYN-001</li><li>관할 가상새빛시</li><li>별칭 2개 확인</li></ul></div><div class="context-box"><h3>적용 방법론</h3><ul class="context-list"><li>가격 이상치</li><li>반복 수의계약</li><li>계약 변경 증가</li></ul></div></aside></div>
</main>${footer}</div>`;

const sidebar = `
<aside class="sidebar"><a class="brand" href="?view=workspace"><span class="brand-mark"></span><span class="brand-text">구린네</span></a>
<nav><div class="nav-label">작업</div><a href="#" class="active">▣ <span>대시보드</span></a><a href="#">✓ <span>내 작업</span></a><a href="#">⌕ <span>내부 검색</span></a><div class="nav-label">조사</div><a href="#">◫ <span>Signal</span></a><a href="?view=workspace">▤ <span>사건</span></a><a href="?view=review">◇ <span>검토</span></a><div class="nav-label">운영</div><a href="#">◉ <span>Source</span></a><a href="#">⚙ <span>규칙·작업</span></a><a href="#">☷ <span>감사</span></a></nav><div class="sidebar-user">김조사자<br><span style="color:#899196">Investigator</span></div></aside>`;

const workspace = `
<div class="internal-shell">${sidebar}<div class="internal-content"><header class="internal-topbar"><div><strong>사건 Workspace</strong> <span class="small muted">/ CASE-SYN-014</span></div><div class="badges"><span class="badge caution">저장 안 된 변경 없음</span><button class="secondary-button">⋯</button></div></header>
<main id="main" class="internal-main"><section class="workspace-head"><div class="workspace-head-row"><div><div class="badges"><span class="badge info">UNDER_INVESTIGATION</span><span class="badge neutral">우선순위 보통</span></div><h1>가상새빛시청 안전장비 구매</h1><div class="workspace-meta"><span>version 17</span><span>담당 김조사자</span><span>편집 박편집자</span><span>최종 변경 11분 전</span></div></div><button class="primary-button">다음 필수 작업 열기</button></div></section>
<div class="workspace-grid"><nav class="task-rail" aria-label="사건 작업"><a class="active" href="#">Overview <span class="task-count">3</span></a><a href="#">Signals <span class="task-count">2</span></a><a href="#">Hypotheses <span class="task-count">3</span></a><a href="#">Evidence <span class="task-count">8</span></a><a href="#">Claims <span class="task-count">4</span></a><a href="#">Responses <span class="task-count">1</span></a><a href="#">Agents <span class="task-count">2</span></a><a href="#">Review <span class="task-count">4</span></a><a href="#">Publication</a><a href="#">Timeline</a><a href="#">Audit</a></nav>
<section class="workspace-panel"><div class="eyebrow">현재 사건 요약</div><h2>다음으로 무엇을 확인해야 하는가</h2>
<div class="triad"><article class="triad-box known"><h3>확인된 사실 3</h3><ul><li>20 EA · 단가 240만원</li><li>비교군 12건</li><li>계약 원문 hash 검증</li></ul></article><article class="triad-box unknown"><h3>중요한 미확인 3</h3><ul><li>추가 인증 비용</li><li>보증 시장가치</li><li>모델 세대 동일성</li></ul></article><article class="triad-box response"><h3>소명 상태</h3><ul><li>답변 제출됨</li><li>첨부 2건 scan 완료</li><li>공개 excerpt 미승인</li></ul></article></div>
<h3 style="margin-top:28px">다음 필수 작업</h3><div class="task-list">
<article class="task-item"><span class="task-check"></span><div><strong>소명 첨부의 인증 범위 검증</strong><span>Evidence E7/E8 · 담당 김조사자 · 오늘 16:00</span></div><span class="badge caution">blocker</span></article>
<article class="task-item"><span class="task-check"></span><div><strong>비교군 모델 세대 재확인</strong><span>12건 중 4건 metadata 부족</span></div><span class="badge neutral">data</span></article>
<article class="task-item done"><span class="task-check"></span><div><strong>단위·VAT compatibility 검증</strong><span>2026.07.10 완료 · E2</span></div><span class="badge verified">완료</span></article></div>
<div class="ai-box"><strong>AI 조사 보조 제안</strong><p class="small" style="margin:7px 0 0">첨부 2의 인증서 번호를 원 계약 규격과 대조하는 작업을 제안합니다. 이 제안은 Evidence E7/E8만 사용했으며 사실 판정이나 상태 변경을 수행하지 않았습니다.</p><div style="margin-top:10px"><button class="secondary-button">제안 검토</button> <button class="quiet-button">거절 사유 기록</button></div></div>
</section>
<aside class="context-rail"><section class="context-section"><h3>공개 준비 blocker</h3><div class="blocker">! 소명 excerpt 검증 필요</div><div class="blocker">! 인증 비용 미확인</div></section><section class="context-section"><h3>최근 변경</h3><ul class="context-list"><li>E8 첨부 scan 완료</li><li>Claim C3 limitation 수정</li><li>비교군 2건 제외</li></ul></section><section class="context-section"><h3>연결 객체</h3><ul class="context-list"><li>Signal 2</li><li>Evidence 8</li><li>Claim 4</li><li>Response 1</li></ul></section></aside></div></main></div></div>`;

const review = `
<div class="internal-shell">${sidebar}<div class="internal-content"><header class="internal-topbar"><div><strong>독립 Snapshot 검토</strong> <span class="small muted">/ RS-2026-014-03</span></div><div><span class="badge caution">재인증 7분 남음</span></div></header>
<main id="main" class="internal-main"><section class="workspace-head"><div class="workspace-head-row"><div><div class="badges"><span class="badge verified">자동 gate 12/12 통과</span><span class="badge neutral">snapshot hash 9af2…441c</span></div><h1>가상새빛시청 안전장비 구매 공개 검토</h1><div class="workspace-meta"><span>case version 17</span><span>작성자 김조사자</span><span>검토자 이검토자</span><span>독립성 확인</span></div></div><button class="secondary-button">현재 사건과 diff</button></div></section>
<div class="case-layout"><section class="workspace-panel"><div class="eyebrow">Immutable review target</div><h2>Claim·근거·소명·한계를 한 snapshot으로 검토</h2>
<table class="data-table"><thead><tr><th>Claim</th><th>근거</th><th>소명</th><th>한계</th><th>상태</th></tr></thead><tbody>
<tr><td data-label="Claim">비교군 중앙값은 480,000원이다.</td><td data-label="근거">E2 계산 snapshot</td><td data-label="소명">—</td><td data-label="한계">12건 cohort</td><td data-label="상태"><span class="badge verified">valid</span></td></tr>
<tr><td data-label="Claim">대상 단가는 중앙값의 5.0배다.</td><td data-label="근거">E1, E2</td><td data-label="소명">R1 연결</td><td data-label="한계">인증 비용 미확인</td><td data-label="상태"><span class="badge caution">limitation</span></td></tr>
</tbody></table>
<h3 style="margin-top:28px">검토 기준</h3><div class="task-list">
<article class="task-item done"><span class="task-check"></span><div><strong>모든 사실 claim에 verified evidence가 연결됨</strong><span>4/4 claims</span></div></article>
<article class="task-item done"><span class="task-check"></span><div><strong>당사자 소명과 공개 동의 범위 반영</strong><span>Response R1 · excerpt approved</span></div></article>
<article class="task-item done"><span class="task-check"></span><div><strong>위법·비리 단정 표현 없음</strong><span>prohibited-language gate 통과</span></div></article></div>
<div class="field" style="margin-top:26px"><label for="reason">검토 사유</label><p class="hint">결정과 함께 audit에 영구 기록됩니다.</p><textarea id="reason">근거 연결, 반대 설명과 소명 반영을 확인했습니다. 인증 비용은 중요한 미확인으로 명확히 표시되어 공개 가능하다고 판단합니다.</textarea></div>
<div class="form-actions"><button class="secondary-button">변경 요청</button><div><button class="danger-button">반려</button> <button class="primary-button">게시 승인</button></div></div></section>
<aside class="case-aside"><div class="context-box"><h3>결정 전 확인</h3><ul class="context-list"><li>현재 snapshot과 동일</li><li>작성자 ≠ 검토자</li><li>재인증 유효</li><li>blocker 0</li></ul></div><div class="context-box"><h3>게시 후 결과</h3><p class="small">Public revision 3이 생성되고 이전 revision은 보존됩니다.</p></div></aside></div></main></div></div>`;

const response = `
<div class="form-shell"><header class="response-header"><a class="brand" href="?view=response"><span class="brand-mark"></span><span class="brand-text">구린네 소명 포털</span></a><span class="small muted">요청번호 RR-SYN-014</span></header>
<main id="main" class="form-main"><div class="progress" aria-label="4단계 중 3단계"><span class="active"></span><span class="active"></span><span class="active"></span><span></span></div>
<div class="eyebrow">3 / 4 · 답변 작성</div><h1 style="font-size:2.25rem">질문별 답변과 공개 범위를 확인하세요</h1><p class="lead">제출 전 마지막 단계에서 실제 공개될 수 있는 본문과 첨부를 다시 보여드립니다.</p>
<div class="request-summary"><strong>가상새빛시청 안전장비 구매 관련 소명 요청</strong><p class="small" style="margin:6px 0 0">답변 기한 2026.07.18 18:00 · 자동 저장됨 · 문의 contact@gurine.invalid</p></div>
<form class="form-card"><div class="field"><label for="q1">1. 표시 단가에 포함된 추가 인증·시험 비용을 설명해 주세요.</label><p class="hint">확인 가능한 문서명이나 금액 범위를 포함하면 검증에 도움이 됩니다.</p><textarea id="q1">현장 적합성 시험과 추가 내충격 인증 비용이 포함되어 있습니다. 세부 산출내역은 첨부 1을 참고해 주세요.</textarea></div>
<div class="field"><label for="q2">2. 납품 후 보증·교육 범위는 무엇입니까?</label><textarea id="q2">2년간 부품 보증과 현장 사용자 교육 2회가 포함됩니다.</textarea></div>
<div class="field"><label>첨부 상태</label><div class="choice"><span>✓</span><div><strong>인증비용_산출내역.pdf</strong><br><span class="small muted">1.2 MB · virus scan clean · SHA-256 기록됨</span></div></div></div>
<div class="field"><label>공개 동의 범위</label><label class="choice"><input type="checkbox" checked><span><strong>답변 본문 공개에 동의</strong><br><span class="small muted">편집자가 문맥을 해치지 않는 범위에서 excerpt를 제안하며 제출 전 preview에서 확인합니다.</span></span></label><label class="choice"><input type="checkbox" checked><span><strong>첨부 1 공개에 동의</strong><br><span class="small muted">개인정보와 비공개 정보는 별도 검토됩니다.</span></span></label></div>
<div class="form-actions"><span class="save-state">✓ 09:42 자동 저장</span><div><button type="button" class="secondary-button">이전</button> <button type="button" class="primary-button">제출 전 확인</button></div></div></form></main></div>`;

const views = { home, case: caseView, search, agency, workspace, review, response };
app.innerHTML = views[view] || home;
if (!['workspace','review','response'].includes(view)) {
  const slot = document.querySelector('#header-slot');
  if (slot) slot.replaceWith(header());
}
document.querySelectorAll('.prototype-switcher a').forEach(a => a.classList.toggle('active', a.dataset.view === view));
