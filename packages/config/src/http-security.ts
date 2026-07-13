export function applyBrowserSecurityHeaders(
  headers: Headers,
  production: boolean,
) {
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  headers.set("Cross-Origin-Resource-Policy", "same-origin");
  headers.set(
    "Permissions-Policy",
    "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
  );
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Frame-Options", "DENY");
  if (production)
    headers.set(
      "Strict-Transport-Security",
      "max-age=31536000; includeSubDomains",
    );
}

export function unsafeCrossOrigin(
  request: Request,
  expectedOrigin: string,
): boolean {
  if (["GET", "HEAD", "OPTIONS"].includes(request.method.toUpperCase()))
    return false;
  const origin = request.headers.get("origin");
  const fetchSite = request.headers.get("sec-fetch-site");
  return (
    origin !== expectedOrigin ||
    (fetchSite !== null && fetchSite !== "same-origin")
  );
}

export function crossOriginProblem(): Response {
  return Response.json(
    {
      type: "about:blank",
      title: "요청 출처를 확인할 수 없습니다.",
      status: 403,
      code: "CSRF_ORIGIN_DENIED",
    },
    { status: 403, headers: { "cache-control": "no-store" } },
  );
}
