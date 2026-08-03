# 55. Rustful·Svelteful 코드 품질 계약

구린네의 코드는 단순히 컴파일되는 코드가 아니라 해당 생태계의 관용구와 안전성을 지키는 코드여야 한다.
권위 규칙은 `AGENTS.md`와 `specs/engineering/code-quality-contract.yaml`이다.

## Rust

모든 first-party crate는 `#![forbid(unsafe_code)]`로 컴파일한다. unsafe block/function/trait/impl과 직접 FFI는
허용하지 않는다. Domain은 exhaustive enum, newtype, typed error와 유효한 상태만 생성 가능한 constructor를
사용한다. Handler에 SQL이나 business rule을 두지 않는다.

## Svelte

Svelte 5의 server load, form action, runes, snippets와 progressive enhancement를 사용한다. React 패턴을
복제하거나 서버 권위 데이터를 store에 중복 저장하지 않는다. Browser는 내부 API와 token을 직접 다루지 않는다.

## SOLID·YAGNI·Clean Code

SOLID는 trait와 파일 수를 늘리는 명분이 아니다. 책임·경계·의존성 방향을 명확히 하되 실제 요구가 없는
추상화는 만들지 않는다. 큰 파일과 함수는 책임이 섞였다는 신호로 취급하며 hard limit 초과는 CI 실패다.
