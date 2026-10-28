"use strict";

/**
 * Portal that accepts the email on the first try but rejects the
 * national-format phone number until it is sent as +44 international.
 * Proves the correction loop only re-touches FLAGGED fields — the
 * already-accepted email must never be written to again.
 */

const { createDocument } = require("./dom-shim");
const { el, labelFor, button } = require("./build-helpers");

function build() {
  const doc = createDocument();
  doc.title = "Guest WiFi";

  const phoneInput = el(doc, "input", {
    type: "tel",
    id: "phone",
    name: "phone",
    required: "",
  });
  const emailInput = el(doc, "input", {
    type: "email",
    id: "email",
    name: "email",
    required: "",
  });
  const submitBtn = button(doc, "Connect to WiFi", { type: "submit" });

  const form = el(doc, "form", {}, [
    labelFor(doc, "phone", "Mobile number"),
    phoneInput,
    labelFor(doc, "email", "Email address"),
    emailInput,
    submitBtn,
  ]);
  doc.body.appendChild(form);

  let emailInputEventCount = 0;
  emailInput.addEventListener("input", function () {
    emailInputEventCount += 1;
  });

  submitBtn.addEventListener("click", function () {
    if (/^\+44\d{10}$/.test(phoneInput.value)) {
      doc.body.removeChild(form);
      doc.body.appendChild(el(doc, "div", {}, ["Connected."]));
      return;
    }
    // Email is always accepted; only phone is ever flagged.
    phoneInput.setAttribute("aria-invalid", "true");
  });

  return {
    doc,
    identity: { phone: "07700900123", email: "guest@example.com" },
    phoneInput: phoneInput,
    emailInput: emailInput,
    getEmailInputEventCount: () => emailInputEventCount,
  };
}

module.exports = { build };
