use super::*;

impl EconomicsInvoiceImportV1 {
    pub(in super::super::super) fn validate(&self) -> Result<(), ServiceError> {
        self.invoice.validate()?;
        if !self.counts_match() {
            return Err(ServiceError::InvalidRequest);
        }
        self.validate_discount_sources()?;
        self.validate_lines()?;
        self.validate_memberships()
    }

    fn counts_match(&self) -> bool {
        !self.lines.is_empty()
            && i32::try_from(self.lines.len()).ok() == Some(self.invoice.expected_line_count)
            && i32::try_from(self.memberships.len()).ok()
                == Some(self.invoice.expected_usage_membership_count)
    }

    fn validate_discount_sources(&self) -> Result<(), ServiceError> {
        let mut identities = BTreeSet::new();
        for source in &self.discounts {
            source.validate()?;
            let Some(identity) = source.identity_digest() else {
                return Err(ServiceError::InvalidRequest);
            };
            if !identities.insert(identity.as_str()) {
                return Err(ServiceError::InvalidRequest);
            }
        }
        Ok(())
    }

    fn validate_lines(&self) -> Result<(), ServiceError> {
        let mut line_sources = BTreeSet::new();
        let mut referenced_discounts = BTreeSet::new();
        let mut totals = InvoiceTotals::zero();
        for (index, line) in self.lines.iter().enumerate() {
            line.validate()?;
            if usize::try_from(line.line_ordinal).ok() != Some(index + 1)
                || !line_matches_invoice(line, &self.invoice)
                || !line_sources.insert(line.source_line_digest.as_str())
            {
                return Err(ServiceError::InvalidRequest);
            }
            if let Some(discount_index) =
                validate_line_discount_binding(line, &self.invoice, &self.discounts)?
            {
                referenced_discounts.insert(discount_index);
            }
            totals.add(line);
        }
        if referenced_discounts.len() != self.discounts.len() || !totals.matches(&self.invoice) {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }

    fn validate_memberships(&self) -> Result<(), ServiceError> {
        let mut usage_roots = BTreeSet::new();
        let mut usage_references = BTreeSet::new();
        let mut membership_roots = BTreeSet::new();
        for membership in &self.memberships {
            membership.validate()?;
            let reference = (
                membership.usage_fact_id,
                membership.usage_fact_revision,
                membership.usage_fact_digest.as_str(),
                membership.usage_window_receipt_id,
                membership.usage_window_receipt_version,
                membership.usage_window_receipt_digest.as_str(),
            );
            if !membership_roots.insert(membership.root_membership_id)
                || !usage_roots.insert(membership.usage_root_fact_id)
                || !usage_references.insert(reference)
                || !membership_matches_invoice(membership, &self.invoice, &self.lines)
            {
                return Err(ServiceError::InvalidRequest);
            }
        }
        Ok(())
    }
}

struct InvoiceTotals {
    subtotal: Decimal,
    discount: Decimal,
    taxable: Decimal,
    tax: Decimal,
    correction: Decimal,
    total: Decimal,
}

impl InvoiceTotals {
    const fn zero() -> Self {
        Self {
            subtotal: Decimal::ZERO,
            discount: Decimal::ZERO,
            taxable: Decimal::ZERO,
            tax: Decimal::ZERO,
            correction: Decimal::ZERO,
            total: Decimal::ZERO,
        }
    }

    fn add(&mut self, line: &EconomicsInvoiceLineImportV1) {
        self.subtotal += line.expected_subtotal;
        self.discount += line.expected_discount_amount;
        self.taxable += line.expected_taxable_amount;
        self.tax += line.expected_tax_amount;
        self.correction += line.expected_correction_amount;
        self.total += line.expected_line_total;
    }

    fn matches(&self, invoice: &EconomicsInvoiceHeaderImportV1) -> bool {
        (
            self.subtotal,
            self.discount,
            self.taxable,
            self.tax,
            self.correction,
            self.total,
        ) == (
            invoice.expected_subtotal,
            invoice.expected_discount_total,
            invoice.expected_taxable_amount,
            invoice.expected_tax_total,
            invoice.expected_correction_total,
            invoice.expected_invoice_total,
        )
    }
}
