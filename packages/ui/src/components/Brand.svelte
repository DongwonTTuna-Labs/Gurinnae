<script lang="ts">
let {
  label = "구린네",
  variant = "public",
}: { label?: string; variant?: "public" | "internal" } = $props();
</script>

<a class:internal={variant === "internal"} class="brand" href="/" aria-label="구린네 홈">
  <span class="brand-mark" aria-hidden="true"></span>
  <span class="brand-text">{label}</span>
</a>

<style>
.brand {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  color: inherit;
  font-weight: 760;
  letter-spacing: -0.025em;
  text-decoration: none;
}

.brand-mark {
  position: relative;
  width: 26px;
  height: 26px;
  flex: none;
  border: 2px solid currentColor;
  border-radius: var(--radius-sm);
  background: var(--paper-0);
}

.brand-mark::before,
.brand-mark::after {
  position: absolute;
  left: 6px;
  height: 2px;
  background: var(--blue-700);
  content: "";
}

.brand-mark::before {
  top: 8px;
  right: 6px;
}

.brand-mark::after {
  top: 15px;
  width: 8px;
}

.brand-text {
  font-size: 1rem;
}

.brand.internal {
  min-height: 2.75rem;
  padding: 0.25rem 0.5rem 0.75rem;
}

.brand.internal .brand-mark {
  background: transparent;
}

@media (max-width: 820px) {
  .brand.internal {
    justify-content: center;
  }

  .brand.internal .brand-text {
    display: none;
  }
}

@media (max-width: 620px) {
  .brand.internal {
    display: none;
  }
}
</style>
