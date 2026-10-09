<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

- Clearing-house pension and capital holdings are adjusted to the break date only from attributable actual deposits within six calendar months; otherwise the workflow blocks, because estimates could create an incorrect legal-financial report. A holding the institution reports as inactive with no listed deposits needs no deduction and does not block, because there is nothing to attribute.
- Opinion pages are measured and paginated at one fixed A4 layout before preview and export, splitting tables at rows with repeated headers and lists at items, so viewer width cannot change wrapping or let content enter the letterhead margins.
- Clearing-house PDFs without a text layer, or whose direct text parse fails or mismatches the first-page totals, are transcribed by the AI gateway via a public server function bridged through the /app iframe; classification, deposit attribution and the stated-total checksum stay in the browser, because the model must only copy values and a mismatch must reject the read.
- A fund or capital asset opened on or after the break date has a 0% transfer share and gets no פסיקתא, because nothing in it accrued during the partnership. A party already retired at the break is valued only on the payments from the break onward.
- Retirement ages and life expectancies are calculation settings (defaults 67/65 and 81.7/85.7, as in the signed opinions) and are printed in chapter 1 of the opinion; whatever the screen computes, the report states.
- The headline result and the opinion's bottom line come from the same `balanceSummary`, so the number on screen is always the number in the report. Payer and payee are identified by party index, never by name.
- Capital-gains tax is 25% of the taxable gain when one is entered, otherwise 25% of the whole balance, and the opinion says which was used. Taxability comes from the product kind as well as the plan name.
- Break-date deduction counts deposits by salary month (XML `YYYYMM` and PDF `MM/YYYY` alike) and never deducts a deposit whose value date is after the balance date, since it is not in that balance.
- Uploading reports of two different people to one side blocks the workflow; IDs are compared without leading zeros. Israeli ID check digits are validated before the report.
- `tests/run.mjs` drives the real page in headless Chromium (`NODE_PATH="$(npm root -g)" node tests/run.mjs`); run it after any change to the calculator.
- Amounts read from clearing-house reports keep their agorot (a monthly pension of 3,605.40 is not rounded to 3,605 — that moved a real case's discounted value by ₪40). Names read from reports are stored surname first, as in the signed opinions, because the opinion takes the personal name from the last word.
