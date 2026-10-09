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

- Clearing-house holdings are adjusted to the break date as the signed opinions do: actual post-break deposits up to the balance date are deducted; post-break salary months that precede the report's deposit listing are estimated at the median monthly deposit, marked "estimated" and disclosed per fund in chapter 1. A month missing inside the listed period is not estimated. A row with no reported salary and an outsized amount is treated as a transfer-in (ניוד), not deducted, and disclosed. Only a report dated before the break, a missing balance date, or an active fund with no deposits to estimate from blocks the workflow.
- A section-47 deposit repeated in the employee column of the same row is counted once.
- The opinion presents both alternatives, as the signed opinions do: א׳ — פסיקתות for the pension plus cash for capital assets; ב׳ — everything in cash. The headline shows ב׳ as the bottom line. A capital asset can be marked "not balanced by agreement"; it is listed in the report and left out of the totals.
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
- Deposit tables are attributed by their own header row (policy number, then managing company, product type, active status), because several funds of one person often share the ID as policy number. An attribution that stays ambiguous is not made.
- A salary month that starts on or after the break date is post-break: with a break on the 1st, that whole month's deposits are deducted; with a mid-month break, the break month stays in the partnership.
- A study fund is liquid at the break when its reported tax-benefit eligibility date is on or before the break; otherwise six years from the first join date (not the plan opening date, which resets on transfer).
- The transfer share of a fund read from a report runs from its first join date (seniority) when that is earlier than the current plan's opening date, because a plan's opening date resets on transfer.
- A provident fund (קופת גמל, active or not, including a central severance fund) is pension savings under the law and gets a פסיקתא; in alternative א׳ it moves by פסיקתא, in ב׳ it is balanced in cash. An investment provident fund (גמל להשקעה) and a study fund get no פסיקתא and are always balanced in cash.
