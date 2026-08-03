<footer class="footer"><div class="footer-inner"><p>구린네는 자동 분석 결과를 범죄 또는 비리의 확정 판단으로 표현하지 않습니다.</p><nav aria-label="푸터 탐색"><a href="/methodology">검증 방법</a><a href="/coverage">데이터 범위</a><a href="/sources">출처</a><a href="/data">데이터 정책</a><a href="/api">API</a><a href="/about">소개</a><a href="/about/funding">후원·재정</a><a href="/about/governance">거버넌스</a><a href="/editorial-policy">편집 정책</a><a href="/corrections">정정</a><a href="/correction-request">정정 요청</a><a href="/accessibility">접근성</a><a href="/contact">도움말·문의</a><a href="/privacy">개인정보</a><a href="/terms">이용약관</a></nav></div></footer>

<style>
.footer {
  padding: 16px 24px;
  border-top: 1px solid var(--paper-200);
  color: var(--ink-500);
  font-size: 0.8125rem;
}

.footer-inner {
  max-width: var(--max);
  margin: 0 auto;
  display: grid;
  grid-template-columns: minmax(16rem, 1fr) minmax(32rem, 2fr);
  gap: 24px;
  align-items: start;
}

p {
  margin: 0;
  line-height: 1.55;
}

nav {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 8px 16px;
}

a {
  color: inherit;
  line-height: 1.45;
  text-underline-offset: 3px;
}

@media (max-width: 820px) {
  .footer-inner {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 620px) {
  .footer {
    padding: 20px 16px;
  }

  nav {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px 14px;
  }
}
</style>
