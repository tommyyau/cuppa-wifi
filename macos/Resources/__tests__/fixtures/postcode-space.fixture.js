"use strict";

/**
 * Portal that rejects a compacted postcode ("SW1A1AA") and only
 * accepts the spaced form ("SW1A 1AA").
 */

const { createDocument } = require("./dom-shim");
const { el, labelFor, button } = require("./build-helpers");

const SPACED_UK_POSTCODE_RE = /^[A-Z]{1,2}\d[A-Z\d]?\s\d[A-Z]{2}$/i;

function build() {
  const doc = createDocument();
  doc.title = "Guest WiFi";

  const postcodeInput = el(doc, "input", {
    type: "text",
    id: "postcode",
    name: "postcode",
    required: "",
  });
  const errorText = el(doc, "p", { id: "postcode-error" }, [""]);
  const submitBtn = button(doc, "Continue", { type: "submit" });

  const form = el(doc, "form", {}, [
    labelFor(doc, "postcode", "Postcode"),
    postcodeInput,
    errorText,
    submitBtn,
  ]);
  doc.body.appendChild(form);

  submitBtn.addEventListener("click", function () {
    if (SPACED_UK_POSTCODE_RE.test(postcodeInput.value)) {
      doc.body.removeChild(form);
      doc.body.appendChild(el(doc, "div", {}, ["Thanks, you're online."]));
      return;
    }
    postcodeInput.setAttribute("aria-invalid", "true");
    errorText.textContent = "Please enter a valid postcode.";
  });

  return { doc, identity: { postcode: "SW1A1AA" }, postcodeInput: postcodeInput };
}

module.exports = { build };
