"use strict";

/**
 * Portal that rejects an ISO date of birth ("1988-03-14") and only
 * accepts UK day-first slash format ("14/03/1988").
 */

const { createDocument } = require("./dom-shim");
const { el, labelFor, button } = require("./build-helpers");

const DD_MM_YYYY_RE = /^\d{2}\/\d{2}\/\d{4}$/;

function build() {
  const doc = createDocument();
  doc.title = "Guest WiFi";

  const dobInput = el(doc, "input", {
    type: "text",
    id: "dob",
    name: "dob",
    required: "",
  });
  const errorText = el(doc, "p", { id: "dob-error" }, [""]);
  const submitBtn = button(doc, "Continue", { type: "submit" });

  const form = el(doc, "form", {}, [
    labelFor(doc, "dob", "Date of birth"),
    dobInput,
    errorText,
    submitBtn,
  ]);
  doc.body.appendChild(form);

  submitBtn.addEventListener("click", function () {
    if (DD_MM_YYYY_RE.test(dobInput.value)) {
      doc.body.removeChild(form);
      doc.body.appendChild(el(doc, "div", {}, ["Age confirmed, you're online."]));
      return;
    }
    dobInput.setAttribute("aria-invalid", "true");
    errorText.textContent = "Please enter your date of birth as dd/mm/yyyy.";
  });

  return { doc, identity: { dob: "1988-03-14" }, dobInput: dobInput };
}

module.exports = { build };
