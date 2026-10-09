export type DCInput = {
  currentAge: number;
  retirementAge: number;
  currentSavings: number;
  annualSalary: number;
  employeeRate: number; // percent of salary
  employerRate: number; // percent of salary
  salaryGrowth: number; // percent
  investmentReturn: number; // percent
  fees: number; // percent
  inflation: number; // percent
};

export type YearRow = {
  age: number;
  year: number;
  salary: number;
  contribution: number;
  growth: number;
  balance: number;
  realBalance: number;
};

export function projectDC(i: DCInput): YearRow[] {
  const rows: YearRow[] = [];
  const years = Math.max(0, Math.round(i.retirementAge - i.currentAge));
  const g = i.salaryGrowth / 100;
  const r = (i.investmentReturn - i.fees) / 100;
  const inf = i.inflation / 100;
  let balance = i.currentSavings;
  let salary = i.annualSalary;

  for (let n = 1; n <= years; n++) {
    const contribution = salary * ((i.employeeRate + i.employerRate) / 100);
    // contributions assumed mid-year
    const growth = balance * r + contribution * (Math.pow(1 + r, 0.5) - 1);
    balance = balance + contribution + growth;
    rows.push({
      age: i.currentAge + n,
      year: n,
      salary,
      contribution,
      growth,
      balance,
      realBalance: balance / Math.pow(1 + inf, n),
    });
    salary = salary * (1 + g);
  }
  return rows;
}

/**
 * Actuarial life annuity factor (ä_x) — present value of $1/yr paid in advance,
 * with simple Gompertz–Makeham survival and a level discount rate.
 */
export function annuityFactor(age: number, discountRate: number, mortality: "standard" | "improved" = "standard") {
  const v = 1 / (1 + discountRate / 100);
  // Gompertz parameters, loosely calibrated to modern annuitant tables
  const m = mortality === "improved" ? 92 : 88;
  const b = mortality === "improved" ? 11.5 : 10.5;
  let survival = 1;
  let factor = 0;
  for (let t = 0; t < 120 - age; t++) {
    factor += survival * Math.pow(v, t);
    const x = age + t;
    const qx = Math.min(1, (1 / b) * Math.exp((x - m) / b));
    survival *= Math.max(0, 1 - qx);
    if (survival < 1e-6) break;
  }
  return factor;
}

/** Monthly annuity payable in advance from a lump sum. */
export function monthlyIncomeFromPot(pot: number, age: number, discountRate: number, mortality: "standard" | "improved" = "standard") {
  const ax = annuityFactor(age, discountRate, mortality);
  // adjust annual-in-advance to monthly-in-advance (standard 11/24 approximation)
  const monthlyFactor = ax - 11 / 24;
  return monthlyFactor > 0 ? pot / monthlyFactor / 12 : 0;
}

export type DBInput = {
  finalSalary: number;
  serviceYears: number;
  accrualDenominator: number; // e.g. 60 => 1/60th per year
  retirementAge: number;
  discountRate: number;
  mortality: "standard" | "improved";
};

export function computeDB(i: DBInput) {
  const annualPension = (i.finalSalary * i.serviceYears) / i.accrualDenominator;
  const ax = annuityFactor(i.retirementAge, i.discountRate, i.mortality);
  return {
    annualPension,
    monthlyPension: annualPension / 12,
    annuityFactor: ax,
    presentValue: annualPension * ax,
    replacementRatio: i.finalSalary > 0 ? annualPension / i.finalSalary : 0,
  };
}

export const money = (n: number, currency = "USD") =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency,
    maximumFractionDigits: 0,
  }).format(Number.isFinite(n) ? n : 0);
