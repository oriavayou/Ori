/* Tests for the calculator page. They run the real page in headless Chromium
   and call its functions, then drive the wizard end to end with a synthetic
   clearing-house (Mimshak) XML file.

     NODE_PATH="$(npm root -g)" node tests/run.mjs                                                   */
import assert from "node:assert/strict";
import { openPage } from "./harness.mjs";

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

/* ---------- independent reference implementations ---------- */
const DAY = 86400000;
const refAnnuityDue = (P, i, n) =>
  i === 0 ? P * n : (P * (1 - Math.pow(1 + i, -n / 12))) / (1 - Math.pow(1 + i, -1 / 12));
function israeliIdCheckDigit(eight) {
  let sum = 0;
  for (let k = 0; k < 8; k++) {
    let d = +eight[k] * (k % 2 ? 2 : 1);
    if (d > 9) d -= 9;
    sum += d;
  }
  return String((10 - (sum % 10)) % 10);
}
const ID_A = "01234567" + israeliIdCheckDigit("01234567");
const ID_B = "31234567" + israeliIdCheckDigit("31234567");
const ID_C = "20000001" + israeliIdCheckDigit("20000001");

/* ---------- synthetic Mimshak XML ---------- */
function mimshakXml({ first, last, id, birth, min, funds }) {
  const lakoach = `<YeshutLakoach><SHEM-PRATI>${first}</SHEM-PRATI><SHEM-MISHPACHA>${last}</SHEM-MISHPACHA>
    <MISPAR-ZIHUY-LAKOACH>${id}</MISPAR-ZIHUY-LAKOACH><TAARICH-LEYDA>${birth}</TAARICH-LEYDA><MIN>${min}</MIN></YeshutLakoach>`;
  const mutzarim = funds
    .map(
      (f) => `
    <Mutzar>
      <NetuneiMutzar><SUG-MUTZAR>${f.sug}</SUG-MUTZAR>${lakoach}</NetuneiMutzar>
      <HeshbonOPolisa>
        <MISPAR-POLISA-O-HESHBON>${f.acct}</MISPAR-POLISA-O-HESHBON>
        <SHEM-TOCHNIT>${f.plan}</SHEM-TOCHNIT>
        ${f.keren ? `<SUG-KEREN-PENSIA>${f.keren}</SUG-KEREN-PENSIA>` : ""}
        <STATUS-POLISA-O-CHESHBON>1</STATUS-POLISA-O-CHESHBON>
        <TAARICH-HITZTARFUT-MUTZAR>${f.opened}</TAARICH-HITZTARFUT-MUTZAR>
        <BlockItrot><Yitrot><TAARICH-ERECH-TZVIROT>${f.asOf}</TAARICH-ERECH-TZVIROT>
          <PerutYitrot><TOTAL-CHISACHON-MTZBR>${f.balance}</TOTAL-CHISACHON-MTZBR></PerutYitrot></Yitrot></BlockItrot>
        ${
          f.kitzba
            ? `<YitraLefiGilPrisha><GIL-PRISHA>${f.gil || 67}</GIL-PRISHA><Kupa><SUG-KUPA>1</SUG-KUPA>
          <KITZVAT-HODSHIT-TZFUYA>${f.kitzba}</KITZVAT-HODSHIT-TZFUYA></Kupa></YitraLefiGilPrisha>`
            : ""
        }
        <PerutHafkadot>${(f.deposits || [])
          .map(
            (d) => `<Hafkada><TAARICH-ERECH-HAFKADA>${d.value}</TAARICH-ERECH-HAFKADA>
          <CHODESH-SACHAR>${d.month}</CHODESH-SACHAR><SCHUM-HAFKADA-OVED>${d.amount}</SCHUM-HAFKADA-OVED></Hafkada>`,
          )
          .join("")}</PerutHafkadot>
      </HeshbonOPolisa>
    </Mutzar>`,
    )
    .join("");
  return `<?xml version="1.0" encoding="UTF-8"?><Mimshak><YeshutYatzran><SHEM-YATZRAN>הראל</SHEM-YATZRAN>${mutzarim}</YeshutYatzran></Mimshak>`;
}
/* monthly deposits of 1,000 from Jan 2025 through Sep 2025, paid on the 10th of the next month */
const monthlyDeposits = () =>
  Array.from({ length: 9 }, (_, k) => {
    const m = k + 1,
      pm = m + 1;
    return {
      month: `2025${String(m).padStart(2, "0")}`,
      value: `2025${String(pm).padStart(2, "0")}10`,
      amount: 1000,
    };
  });
const PERSON_A = {
  first: "דנה",
  last: "כהן",
  id: ID_A,
  birth: "19800510",
  min: "2",
  funds: [
    {
      sug: 2,
      keren: 2,
      acct: "000123456",
      plan: "הראל פנסיה מקיפה",
      opened: "20050301",
      asOf: "20250930",
      balance: 300000,
      kitzba: 4200.4,
      gil: 67,
      deposits: monthlyDeposits(),
    },
    /* study fund whose plan name does not say "השתלמות" — taxed by its product kind */
    {
      sug: 4,
      acct: "777",
      plan: "הראל כללי",
      opened: "20220101",
      asOf: "20250930",
      balance: 80000,
      deposits: monthlyDeposits(),
    },
  ],
};

/* ---------- unit tests on page functions ---------- */
test("transfer share: before marriage, after marriage, after break", async (page) => {
  const r = await page.evaluate(() => {
    const brk = parseDate("2025-06-30"),
      mar = parseDate("2010-01-01");
    return {
      before: transferShare(mar, brk, parseDate("2005-01-01")),
      afterMarriage: transferShare(mar, brk, parseDate("2015-01-01")),
      afterBreak: transferShare(mar, brk, parseDate("2025-09-01")),
      onBreak: transferShare(mar, brk, parseDate("2025-06-30")),
      marriageAfterBreak: transferShare(parseDate("2026-01-01"), brk, parseDate("2005-01-01")),
    };
  });
  const shared = (Date.UTC(2025, 5, 30) - Date.UTC(2010, 0, 1)) / DAY / 365;
  const accrual = (Date.UTC(2025, 5, 30) - Date.UTC(2005, 0, 1)) / DAY / 365;
  assert.ok(Math.abs(r.before.share - shared / accrual / 2) < 1e-12);
  assert.equal(r.afterMarriage.share, 0.5);
  assert.equal(r.afterBreak.share, 0, "a fund opened after the break has no marital share");
  assert.equal(r.afterBreak.afterBreak, true);
  assert.equal(r.onBreak.share, 0);
  assert.equal(r.marriageAfterBreak.share, 0, "never a negative share");
});

test("life expectancy and retirement dates match the signed-opinion convention", async (page) => {
  const r = await page.evaluate(() => [
    dateFmt(mortalityDate(parseDate("1980-05-10"), "male")),
    dateFmt(mortalityDate(parseDate("1980-05-10"), "female")),
    dateFmt(retireDate(parseDate("1980-05-10"), "male")),
    dateFmt(retireDate(parseDate("1980-05-10"), "female")),
    dateFmt(mortalityDate(parseDate("1975-12-25"), "male")),
  ]);
  /* 81.7 years = 81 years, 8 months and 12 days */
  assert.deepEqual(r, ["22/01/2062", "22/01/2066", "10/05/2047", "10/05/2045", "06/09/2057"]);
});

test("pension value equals an independent annuity-due computation", async (page) => {
  const r = await page.evaluate(() => {
    const c = computePerson(
      { birth: "1980-05-10", gender: "male", funds: [{ amount: 5000, opened: "2005-01-01" }] },
      0.03,
      parseDate("2025-06-30"),
      null,
      0.35,
      parseDate("2010-01-01"),
    );
    return {
      atBreak: c.atBreak,
      months: c.months,
      years: c.years,
      ret: +c.retire,
      death: +c.death,
    };
  });
  const months = Math.round((r.death - r.ret) / DAY / 30.4375);
  const years = (r.ret - Date.UTC(2025, 5, 30)) / DAY / 365;
  assert.equal(r.months, months);
  assert.ok(Math.abs(r.years - years) < 1e-12);
  const expected = refAnnuityDue(5000, 0.03, months) / Math.pow(1.03, years);
  assert.ok(Math.abs(r.atBreak - expected) < 1e-6, `${r.atBreak} vs ${expected}`);
});

test("already retired at the break: only payments from the break onward count", async (page) => {
  const r = await page.evaluate(() => {
    const c = computePerson(
      { birth: "1955-01-01", gender: "male", funds: [{ amount: 5000, opened: "2000-01-01" }] },
      0.03,
      parseDate("2025-06-30"),
      null,
      0.35,
      parseDate("2010-01-01"),
    );
    return {
      months: c.months,
      years: c.years,
      atBreak: c.atBreak,
      death: +c.death,
      retiredAtBreak: c.retiredAtBreak,
    };
  });
  const months = Math.round((r.death - Date.UTC(2025, 5, 30)) / DAY / 30.4375);
  assert.equal(r.retiredAtBreak, true);
  assert.equal(r.years, 0);
  assert.equal(r.months, months);
  assert.ok(Math.abs(r.atBreak - refAnnuityDue(5000, 0.03, months)) < 1e-6);
});

test("capital gains tax: 25% of the stated gain, or of the balance when unknown; study fund detected by kind", async (page) => {
  const r = await page.evaluate(() => {
    const run = (capital) =>
      computePerson(
        { birth: "1980-05-10", gender: "male", funds: [], capital },
        0.03,
        parseDate("2025-06-30"),
        null,
        0.35,
        parseDate("2010-01-01"),
      ).capItems[0];
    return {
      noGain: run([{ name: "כלל השתלמות", amount: 100000, opened: "2020-01-01" }]),
      gain: run([{ name: "כלל השתלמות", amount: 100000, opened: "2020-01-01", gain: 20000 }]),
      byKind: run([
        { name: "הראל כללי", kind: "קרן השתלמות", amount: 100000, opened: "2020-01-01" },
      ]),
      liquid: run([{ name: "כלל השתלמות", amount: 100000, opened: "2010-01-01", liquid: true }]),
      gemel: run([{ name: "קופת גמל", amount: 100000, opened: "2020-01-01" }]),
    };
  });
  assert.equal(r.noGain.tax, 25000);
  assert.equal(r.gain.tax, 5000);
  assert.equal(r.gain.taxOnGain, true);
  assert.equal(r.byKind.tax, 25000);
  assert.equal(r.liquid.tax, 0);
  assert.equal(r.gemel.tax, 0);
});

test("break-date adjustment: deducts post-break salary months, ignores deposits after the balance date", async (page) => {
  const r = await page.evaluate(() => {
    const deposits = [
      { valueDate: "2025-06-10", salaryMonth: "05/2025", amount: 1000 },
      { valueDate: "2025-07-10", salaryMonth: "202506", amount: 1000 } /* break month — stays */,
      { valueDate: "2025-08-10", salaryMonth: "202507", amount: 1000 } /* deducted */,
      { valueDate: "2025-09-10", salaryMonth: "08/2025", amount: 1000 } /* deducted */,
      {
        valueDate: "2025-10-10",
        salaryMonth: "09/2025",
        amount: 1000,
      } /* after the balance date */,
      { valueDate: "2025-01-10", salaryMonth: "12/2024", amount: 1000 },
    ];
    return adjustFundToBreak(
      { balance: 300000, kitzba: 4000, asOf: "2025-09-30", active: true, deposits },
      parseDate("2025-06-30"),
    );
  });
  assert.equal(r.adjustmentStatus, "ok");
  assert.equal(r.deducted, 2000);
  assert.equal(r.balance, 298000);
  assert.ok(Math.abs(r.kitzba - Math.round(((4000 * 298000) / 300000) * 100) / 100) < 1e-9);
});

test("break on the 1st of a month: that month's salary is post-break", async (page) => {
  const r = await page.evaluate(() => {
    const deposits = [
      { valueDate: "2025-04-10", salaryMonth: "03/2025", amount: 1000 } /* before — stays */,
      {
        valueDate: "2025-05-10",
        salaryMonth: "04/2025",
        amount: 1000,
      } /* the break month, break on the 1st — deducted */,
      { valueDate: "2025-06-10", salaryMonth: "05/2025", amount: 1000 } /* deducted */,
      { valueDate: "2024-11-10", salaryMonth: "10/2024", amount: 1000 },
    ];
    return adjustFundToBreak(
      { balance: 100000, kitzba: 1000, asOf: "2025-06-30", active: true, deposits },
      parseDate("2025-04-01"),
    ).deducted;
  });
  assert.equal(r, 2000);
});

test("deposit tables go to the fund named in their header when funds share a policy number", async (page) => {
  const r = await page.evaluate(() => {
    const funds = [
      { acct: "38790572", body: "מנורה מבטחים פנסיה", kind: "קרן פנסיה משלימה", active: false },
      { acct: "38790572", body: "מור גמל ופנסיה", kind: "קרן פנסיה מקיפה", active: true },
      { acct: "79136245980", body: "אקסלנס", kind: "קרן השתלמות", active: true },
    ];
    const pick = (h) => {
      const f = pickDepositTarget(funds, h);
      return f ? f.body : null;
    };
    return [
      pick("סוג המוצר :פנסיה חדשה מקיפה | שם חברה מנהלת :מור גמל ופנסיה | מספר פוליסה38790572 :"),
      pick(
        'סוג המוצר :פנסיה חדשה כללית | שם חברה מנהלת :מנורה מבטחים פנסיה וגמל בע"מ | מספר פוליסה38790572 :',
      ),
      pick("סוג המוצר :קרן השתלמות | שם חברה מנהלת :הפניקס | מספר פוליסה79136245980 :"),
      pick("מספר פוליסה 11111111"),
    ];
  });
  assert.deepEqual(r, ["מור גמל ופנסיה", "מנורה מבטחים פנסיה", "אקסלנס", null]);
});

test("study fund liquidity at the break: reported eligibility date, else six years from first join", async (page) => {
  const r = await page.evaluate(() => {
    const brk = parseDate("2025-04-01");
    return [
      studyFundLiquidAt(
        { withdrawable: "31/03/2029", opened: "2023-12-12", firstJoined: "2023-03-31" },
        brk,
      ),
      studyFundLiquidAt(
        { withdrawable: "ניתן למשיכה", opened: "2023-12-12", firstJoined: "2017-01-01" },
        brk,
      ),
      studyFundLiquidAt({ opened: "2023-12-12" }, brk),
      studyFundLiquidAt(
        { withdrawable: "ניתן למשיכה", opened: "2020-01-19", firstJoined: "2020-01-01" },
        parseDate("2026-06-30"),
      ),
    ];
  });
  assert.deepEqual(r, [false, true, false, true]);
});

test("break-date adjustment blocks a report before the break or one with nothing to estimate from", async (page) => {
  const r = await page.evaluate(() => [
    adjustFundToBreak(
      { balance: 1, kitzba: 1, asOf: "2025-05-31", deposits: [] },
      parseDate("2025-06-30"),
    ).adjustmentStatus,
    adjustFundToBreak(
      { balance: 1, kitzba: 1, asOf: "2026-01-31", deposits: [] },
      parseDate("2025-06-30"),
    ).adjustmentStatus,
    adjustFundToBreak(
      { balance: 1, kitzba: 1, asOf: "2025-06-30", deposits: [] },
      parseDate("2025-06-30"),
    ).adjustmentStatus,
  ]);
  assert.deepEqual(r, ["blocked", "blocked", "ok"]);
});

test("report long after the break: listed deposits deducted, earlier months estimated, transfers kept", async (page) => {
  const r = await page.evaluate(() => {
    const deposits = [];
    for (let k = 0; k < 12; k++) {
      /* salary months 05/2025 … 04/2026, 4,000 each, paid the next month */
      const m = new Date(Date.UTC(2025, 4 + k, 1)),
        v = new Date(Date.UTC(2025, 5 + k, 10));
      deposits.push({
        salaryMonth: `${String(m.getUTCMonth() + 1).padStart(2, "0")}/${m.getUTCFullYear()}`,
        valueDate: v.toISOString().slice(0, 10),
        amount: 4000,
        salary: 20000,
      });
    }
    deposits.push({
      salaryMonth: "07/2025",
      valueDate: "2025-07-06",
      amount: 72000,
      salary: 0,
    }); /* transfer-in */
    const f = adjustFundToBreak(
      { balance: 600000, kitzba: 6000, asOf: "2026-05-31", active: true, deposits },
      parseDate("2025-04-01"),
    );
    return {
      status: f.adjustmentStatus,
      deducted: f.deducted,
      actual: f.deductedActual,
      months: f.estimatedMonths,
      transfers: f.transfers.length,
      kitzba: f.kitzba,
    };
  });
  assert.equal(r.status, "estimated");
  assert.equal(r.actual, 48000, "12 listed post-break months");
  assert.deepEqual(
    r.months,
    ["04/2025"],
    "the break month (break on the 1st) precedes the listing",
  );
  assert.equal(r.deducted, 52000);
  assert.equal(r.transfers, 1);
  assert.equal(r.kitzba, Math.round(((6000 * 548000) / 600000) * 100) / 100);
});

test("a capital asset marked not-balanced is listed but left out of the totals", async (page) => {
  const r = await page.evaluate(() => {
    const run = (exclude) =>
      computePerson(
        {
          birth: "1980-05-10",
          gender: "male",
          funds: [],
          capital: [
            { name: "קרן השתלמות", amount: 100000, opened: "2020-01-01", liquid: true, exclude },
          ],
        },
        0.03,
        parseDate("2025-06-30"),
        null,
        0.35,
        parseDate("2010-01-01"),
      );
    const a = run(false),
      b = run(true);
    return {
      a: a.capitalShare,
      b: b.capitalShare,
      bItem: b.capItems[0].excluded,
      bMarital: b.capItems[0].marital,
    };
  });
  assert.equal(r.a, 50000);
  assert.equal(r.b, 0);
  assert.equal(r.bItem, true);
  assert.equal(r.bMarital, 0);
});

test("transfer share runs from the first join date, not the current plan's opening", async (page) => {
  const r = await page.evaluate(() => {
    const p = state.people[0];
    p.intake = {
      rawFunds: [],
      rawCapital: [
        {
          plan: "אקסלנס — קופת גמל",
          kind: "קופת גמל",
          acct: "1",
          balance: 2758.49,
          opened: "2011-11-30",
          firstJoined: "2005-12-04",
          asOf: "2025-12-31",
          active: false,
          deposits: [],
        },
      ],
      skipped: [],
      notes: [],
      errors: [],
    };
    document.querySelector("#breakDate").value = "2024-12-08";
    refreshMaslakaAdjustment(0);
    const sh = transferShare(
      parseDate("2007-03-22"),
      parseDate("2024-12-08"),
      parseDate(p.capital[0].opened),
    );
    return { opened: p.capital[0].opened, share: +(sh.share * 100).toFixed(2) };
  });
  assert.equal(r.opened, "2005-12-04");
  assert.equal(r.share, 46.59, "as in the actuary's opinion for this fund");
});

test("a provident fund gets a פסיקתא; an investment provident fund and a study fund do not", async (page) => {
  const r = await page.evaluate(() => [
    capitalHasPsikta({ name: "אקסלנס — קופת גמל", kind: "קופת גמל" }),
    capitalHasPsikta({ name: "הראל", kind: "קופת גמל מרכזית לפיצויים" }),
    capitalHasPsikta({ name: "מיטב גמל להשקעה", kind: "קופת גמל" }),
    capitalHasPsikta({ name: "כלל", kind: "קרן השתלמות" }),
    capitalHasPsikta({ name: "קופת גמל", atRetire: true }),
  ]);
  assert.deepEqual(r, [true, true, false, false, false]);
});

test("salary month parsing covers PDF and XML formats", async (page) => {
  const r = await page.evaluate(() =>
    ["06/2025", "202506", "20250601", "062025", "2025-06", "6/25", "15/06/2025", "abc"].map((v) => {
      const d = parseSalaryMonth(v);
      return d ? d.toISOString().slice(0, 7) : null;
    }),
  );
  assert.deepEqual(r, [
    "2025-06",
    "2025-06",
    "2025-06",
    "2025-06",
    "2025-06",
    "2025-06",
    "2025-06",
    null,
  ]);
});

test("Israeli ID check digit", async (page) => {
  const r = await page.evaluate(
    (ids) => ids.map(validIsraeliId),
    [ID_A, ID_B, "000000018", "123456789", "000000000", "12"],
  );
  assert.deepEqual(r, [true, true, true, false, false, false]);
});

test("XML reading: person, pension fund, study fund, deposits", async (page) => {
  const xml = mimshakXml(PERSON_A);
  const r = await page.evaluate((xml) => readMaslakaXml(xml, "a.xml"), xml);
  assert.equal(r.error, "");
  assert.equal(r.person.name, "כהן דנה", "surname first, as in the signed opinions");
  assert.equal(r.person.gender, "female");
  assert.equal(r.person.birth, "1980-05-10");
  assert.equal(r.funds.length, 1);
  assert.equal(r.funds[0].kitzba, 4200.4);
  assert.equal(r.funds[0].balance, 300000);
  assert.equal(r.funds[0].acct, "123456");
  assert.equal(r.funds[0].deposits.length, 9);
  assert.equal(r.capital.length, 1);
  assert.equal(r.capital[0].kind, "קרן השתלמות");
});

test("files of two different people on one side are rejected", async (page) => {
  const xa = mimshakXml(PERSON_A);
  const xb = mimshakXml({ ...PERSON_A, first: "יוסי", id: ID_C });
  const r = await page.evaluate(
    ([xa, xb]) => mergeMaslaka([readMaslakaXml(xa, "a.xml"), readMaslakaXml(xb, "b.xml")]),
    [xa, xb],
  );
  assert.equal(r.mixed, true);
  assert.ok(r.errors.some((e) => /יותר מאדם אחד/.test(e.msg)));
  /* the same person with and without leading zeros is one person */
  const same = await page.evaluate((xa) => {
    const one = readMaslakaXml(xa, "a.xml"),
      two = readMaslakaXml(xa, "b.xml");
    two.person = Object.assign({}, two.person, { id: "0" + two.person.id });
    return mergeMaslaka([one, two]).mixed;
  }, xa);
  assert.ok(!same);
});

test("plausibility notes flag a missing or absurd monthly pension", async (page) => {
  const r = await page.evaluate(() =>
    plausibilityNotes({
      funds: [
        { plan: "א", acct: "1", balance: 100000, kitzba: 0 },
        { plan: "ב", acct: "2", balance: 100000, kitzba: 50000 },
        { plan: "ג", acct: "3", balance: 100000, kitzba: 600 },
      ],
    }),
  );
  assert.equal(r.length, 2);
});

/* ---------- end-to-end wizard ---------- */
async function setValue(page, sel, value) {
  await page.evaluate(
    ([sel, value]) => {
      const el = document.querySelector(sel);
      el.value = value;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    },
    [sel, value],
  );
}
const next = async (page) => {
  await page.click("#wizardNext");
  return page.textContent("#wizardStatus");
};

test("full wizard: XML upload, manual spouse, report bottom line equals headline", async (page) => {
  await page.click("#modeCouple");
  await setValue(page, "#breakDate", "2025-06-30");
  let st = await next(page);
  assert.match(st, /שלב 2/);

  await page.setInputFiles("#file0", {
    name: "a.xml",
    mimeType: "text/xml",
    buffer: Buffer.from(mimshakXml(PERSON_A)),
  });
  await page.waitForFunction(() => state.people[0].intake);
  const intake = await page.evaluate(() => ({
    funds: state.people[0].funds,
    cap: state.people[0].capital,
    notes: state.people[0].intake.notes,
  }));
  assert.equal(intake.funds.length, 1);
  assert.equal(
    intake.funds[0].amount,
    Math.round(((4200.4 * 298000) / 300000) * 100) / 100,
    "kitzba adjusted by the deducted deposits",
  );
  assert.equal(intake.cap[0].taxable, true);
  st = await next(page);
  assert.match(st, /שלב 3/, st);

  /* spouse B — entered by hand; first an invalid ID must be rejected */
  await setValue(page, "#name1", "לוי משה");
  await setValue(page, "#gender1", "male");
  await setValue(page, "#birth1", "1978-03-03");
  await setValue(page, "#tz1", "123456789");
  await page.click('[data-add="1"]');
  await setValue(page, '[data-p="1"][data-f="0"][data-k="name"]', "מגדל מקיפה");
  await setValue(page, '[data-p="1"][data-f="0"][data-k="amount"]', "6000");
  await setValue(page, '[data-p="1"][data-f="0"][data-k="opened"]', "2001-01-01");
  st = await next(page);
  assert.match(st, /ספרת הביקורת/);
  await setValue(page, "#tz1", ID_B);
  st = await next(page);
  assert.match(st, /שלב 4/, st);

  await setValue(page, "#marriage", "2008-08-08");
  await setValue(page, "#caseNo", "12345-01-25");
  st = await next(page);
  assert.match(st, /שלב 5/, st);

  const out = await page.evaluate(() => {
    const clean = (t) =>
      t
        .replace(/[\u200e\u200f]/g, "")
        .replace(/\s+/g, " ")
        .trim();
    const total = clean(document.querySelector(".tile.headline .t-value").textContent);
    const sumRows = [...document.querySelectorAll("#opinionDoc tr.sum")].map((tr) =>
      clean(tr.textContent),
    );
    /* a card may continue on the next page with its header repeated — count distinct numbers */
    const psiktot = new Set(
      [...document.querySelectorAll("#opinionDoc .ps-kicker")].map((k) => k.textContent.trim()),
    ).size;
    const text = document.querySelector("#opinionDoc").textContent;
    return { total, sumRows, psiktot, text };
  });
  const bottom = out.sumRows.find((t) => t.startsWith("נטו לתשלום"));
  assert.ok(bottom, out.sumRows.join(" / "));
  assert.ok(bottom.includes(out.total), `headline ${out.total} vs report "${bottom}"`);
  assert.equal(out.psiktot, 2, "one פסיקתא per pension fund");
  assert.match(out.text, /ספטמבר 2025/, "sources line uses the report month");
  assert.doesNotMatch(out.text, /יוני 2026/);
  assert.match(out.text, /הנחת תוחלת חיים/);
  assert.match(out.text, /חלופה א׳/, "both alternatives, as in the signed opinions");
  assert.match(out.text, /חלופה ב׳/);
});

test("rights only for side B: B's breakdown is shown", async (page) => {
  await page.click("#modeSoloB");
  await page.evaluate(() => {
    document.querySelector("#breakDate").value = "2025-06-30";
    document.querySelector("#marriage").value = "2008-08-08";
    Object.assign(state.people[0], { name: "א", gender: "male", birth: "1975-01-01", id: "" });
    Object.assign(state.people[1], {
      name: "ב",
      gender: "female",
      birth: "1980-01-01",
      id: "",
      funds: [{ name: "קרן", amount: 3000, opened: "2000-01-01" }],
    });
    render();
  });
  const heads = await page.$$eval(".locked-body > .breakdown .bd-head h3", (hs) =>
    hs.map((h) => h.textContent),
  );
  assert.ok(
    heads.some((h) => h.startsWith("ב — פירוט מלא")),
    heads.join(" | "),
  );
  assert.ok(!heads.some((h) => h.startsWith("א — פירוט מלא")), heads.join(" | "));
});

/* ---------- runner ---------- */
let failed = 0;
for (const t of tests) {
  const { browser, page, errors } = await openPage();
  try {
    await t.fn(page);
    assert.deepEqual(errors, [], "page errors");
    console.log("ok   -", t.name);
  } catch (e) {
    failed++;
    console.log(
      "FAIL -",
      t.name,
      "\n      ",
      String((e && e.message) || e)
        .split("\n")
        .join("\n       "),
    );
  } finally {
    await browser.close();
  }
}
console.log(`\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed ? 1 : 0);
