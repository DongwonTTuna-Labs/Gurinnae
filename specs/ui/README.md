# Gurine Final Product and UI Specification

상태: **FINAL**

이 디렉터리는 94개 화면의 정보 위계, layout, component, action, API, 상태,
반응형 동작, 접근성, analytics와 금지사항을 결정하는 권위 자료다.

## 권위 순서

1. `FINAL_DESIGN_SYSTEM.md`
2. `design-tokens.yaml`
3. `screen-catalog.yaml`
4. `screen-build-manifest.yaml`
5. `screen-data-contracts.yaml`
6. `component-catalog.yaml`
7. `FINAL_COMPONENT_MANUAL.md`
8. `roles-and-permissions.yaml`
9. `navigation.yaml`
10. `page-archetypes.yaml`
11. `content-patterns.yaml`
12. `analytics-events.yaml`
13. `screens/<SCREEN-ID>.md`
14. `wireframes/*.md`
15. `final-reference/*`

## 화면 완성의 의미

화면 하나는 다음을 모두 구현해야 완성이다.

- stable route와 access mode
- primary job과 user questions
- manifest와 동일한 section 순서
- 정확한 generated client operation
- server-side capability 검사
- loading, success, empty, partial, stale, error
- 내부 화면의 unauthorized, forbidden, conflict, reauth
- wide, medium, compact layout
- keyboard·screen reader·zoom/reflow
- analytics allowlist
- screen-specific no-go
- Playwright와 visual regression

`screen-catalog.yaml`의 모든 화면과 `operation-contracts.yaml`의 모든 operation은
단일 최종 구현 범위다. 선택적 milestone이나 후속 화면은 없다.

## 검증

```bash
make validate-screens
make final-check
```
