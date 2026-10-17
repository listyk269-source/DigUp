"use strict";

// One native-input calendar control for ordinary search and saved People albums.
class YearPeriodControl {
  static options(value) {
    const year = (v) => ["number", "string"].includes(typeof v) && /^\d{1,4}$/.test(String(v)) && +v >= 1 && +v <= 9999 ? +v : null;
    const fromYear = year(value?.fromYear), throughYear = year(value?.throughYear);
    return fromYear != null && throughYear != null && fromYear > throughYear ? { fromYear: null, throughYear: null } : { fromYear, throughYear };
  }
  constructor(prefix, onChange) {
    this.prefix = prefix; this.onChange = onChange; this.error = null;
    this.el = (part) => document.getElementById(prefix + "-" + part);
    for (const end of ["from", "through"]) {
      this.el("year-" + end).onchange = () => this.commit();
      const slider = this.el("year-" + end + "-range");
      slider.oninput = () => {
        const other = this.el("year-" + (end === "from" ? "through" : "from") + "-range");
        if (end === "from" && +slider.value > +other.value || end === "through" && +slider.value < +other.value) other.value = slider.value;
        for (const key of ["from", "through"]) this.el("year-" + key).value = this.el("year-" + key + "-range").value;
        this.draw();
      };
      slider.onchange = () => this.commit();
    }
    this.el("period-reset").onclick = () => { this.error = null; this.onChange({ fromYear: null, throughYear: null }); };
  }
  commit() {
    const first = this.el("year-from"), last = this.el("year-through");
    const fromYear = first.value === "" ? null : Number(first.value), throughYear = last.value === "" ? null : Number(last.value);
    const valid = first.checkValidity() && last.checkValidity() && (fromYear == null || throughYear == null || fromYear <= throughYear);
    this.error = valid ? null : t("The first year must not exceed the last. Use years from 1 to 9999.");
    this.el("period-error").textContent = this.error || "";
    first.setAttribute("aria-invalid", String(!valid)); last.setAttribute("aria-invalid", String(!valid));
    if (valid) this.onChange({ fromYear, throughYear });
  }
  draw() {
    const first = this.el("year-from-range"), last = this.el("year-through-range"), span = +first.max - +first.min || 1;
    this.el("year-rail").style.setProperty("--range-start", ((+first.value - +first.min) / span * 100) + "%");
    this.el("year-rail").style.setProperty("--range-end", ((+last.value - +first.min) / span * 100) + "%");
    first.setAttribute("aria-valuetext", first.value); last.setAttribute("aria-valuetext", last.value);
  }
  render(options, { minYear = 1900, maxYear = new Date().getFullYear(), disabled = false } = {}) {
    const min = Math.min(minYear ?? 1900, options.fromYear ?? 9999, options.throughYear ?? 9999);
    const max = Math.min(9999, Math.max(maxYear ?? new Date().getFullYear(), options.fromYear ?? 1, options.throughYear ?? 1, min));
    for (const end of ["from", "through"]) {
      const input = this.el("year-" + end), slider = this.el("year-" + end + "-range");
      input.value = options[end + "Year"] ?? ""; input.disabled = disabled; input.setAttribute("aria-invalid", String(!!this.error));
      slider.min = min; slider.max = max; slider.value = options[end + "Year"] ?? (end === "from" ? min : max); slider.disabled = disabled || min === max;
    }
    this.el("period-error").textContent = this.error || "";
    this.el("period-label").textContent = options.fromYear == null && options.throughYear == null ? t("All dates") : (options.fromYear ?? min) + " — " + (options.throughYear ?? max);
    this.el("period-reset").disabled = options.fromYear == null && options.throughYear == null && !this.error;
    const ticks = this.el("year-ticks"); ticks.replaceChildren();
    const intervals = Math.min(6, max - min);
    for (let i = 0; i <= intervals; i++) { const tick = document.createElement("span"); tick.textContent = Math.round(min + (max - min) * (intervals ? i / intervals : 0)); ticks.append(tick); }
    this.draw();
  }
}
if (typeof module !== "undefined") module.exports = YearPeriodControl;
