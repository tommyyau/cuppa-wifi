"use strict";

/**
 * Portal that rejects every submission no matter what is sent — proves
 * the retry loop gives up bounded (max 3 correction rounds) rather than
 * looping forever, and reports which fields it never satisfied.
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
  const postcodeInput = el(doc, "input", {
    type: "text",
    id: "postcode",
    name: "postcode",
    required: "",
  });
  const submitBtn = button(doc, "Continue", { type: "submit" });

  const form = el(doc, "form", {}, [
    labelFor(doc, "phone", "Mobile number"),
    phoneInput,
    labelFor(doc, "postcode", "Postcode"),
    postcodeInput,
    submitBtn,
  ]);
  doc.body.appendChild(form);

  let submitCount = 0;
  submitBtn.addEventListener("click", function () {
    submitCount += 1;
    phoneInput.setAttribute("aria-invalid", "true");
    postcodeInput.setAttribute("aria-invalid", "true");
  });

  return {
    doc,
    identity: { phone: "07700900123", postcode: "SW1A1AA" },
    getSubmitCount: () => submitCount,
  };
}

module.exports = { build };
