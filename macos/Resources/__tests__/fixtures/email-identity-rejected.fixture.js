"use strict";

/**
 * Portal that permanently rejects the configured email address (e.g. a
 * mailinator blocklist). Per the reconciled spec, correction must NOT
 * swap the domain for a different relay — the loop must give up with an
 * actionable, value-free emailIdentityRejected report and leave the
 * configured address exactly as it was.
 */

const { createDocument } = require("./dom-shim");
const { el, labelFor, button } = require("./build-helpers");

function build() {
  const doc = createDocument();
  doc.title = "Guest WiFi";

  const emailInput = el(doc, "input", {
    type: "email",
    id: "email",
    name: "email",
    required: "",
  });
  const errorText = el(doc, "p", { id: "email-error" }, [""]);
  const submitBtn = button(doc, "Connect to WiFi", { type: "submit" });

  const form = el(doc, "form", {}, [
    labelFor(doc, "email", "Email address"),
    emailInput,
    errorText,
    submitBtn,
  ]);
  doc.body.appendChild(form);

  const seenValues = [];
  submitBtn.addEventListener("click", function () {
    seenValues.push(emailInput.value);
    emailInput.setAttribute("aria-invalid", "true");
    errorText.textContent = "Please enter a valid email address.";
  });

  return {
    doc,
    identity: { email: "guest.wifi@mailinator.com" },
    emailInput: emailInput,
    getSeenValues: () => seenValues.slice(),
  };
}

module.exports = { build };
