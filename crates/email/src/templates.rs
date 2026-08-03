use crate::port::EmailMessage;

pub struct TemplateContext<'a> {
    pub from: &'a str,
    pub to: &'a str,
    pub action_url: &'a str,
}

pub fn response_request(context: TemplateContext<'_>, due_date: &str) -> EmailMessage {
    let subject = "구린네 소명 요청 안내".to_owned();
    let text_body = format!(
        "소명 요청이 도착했습니다. 제출 기한: {due_date}\n{}",
        context.action_url
    );
    let html_body = format!(
        "<h1>소명 요청</h1><p>제출 기한: {}</p><p><a href=\"{}\">안전한 소명 화면 열기</a></p>",
        escape_html(due_date),
        escape_html(context.action_url)
    );
    EmailMessage {
        from: context.from.to_owned(),
        to: context.to.to_owned(),
        subject,
        text_body,
        html_body,
    }
}

pub fn subscription_verification(context: TemplateContext<'_>) -> EmailMessage {
    EmailMessage {
        from: context.from.to_owned(),
        to: context.to.to_owned(),
        subject: "구린네 구독 확인".to_owned(),
        text_body: format!(
            "구독을 확인하려면 다음 링크를 한 번만 사용하세요.\n{}",
            context.action_url
        ),
        html_body: format!(
            "<p><a href=\"{}\">구독 확인</a></p>",
            escape_html(context.action_url)
        ),
    }
}

pub fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

#[cfg(test)]
mod tests {
    use super::escape_html;

    #[test]
    fn escapes_every_html_text_and_attribute_metacharacter() {
        assert_eq!(
            escape_html("<strong data-value=\"A&B\">'제목'</strong>"),
            "&lt;strong data-value=&quot;A&amp;B&quot;&gt;&#39;제목&#39;&lt;/strong&gt;"
        );
    }
}
