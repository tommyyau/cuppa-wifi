"use strict";

/**
 * Portal that 400s a national UK mobile number and only accepts the
 * +44 international format. The retry must preserve the phone identity.
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
  const errorText = el(doc, "p", { id: "phone-error" }, [""]);
  const submitBtn = button(doc, "Connect to WiFi", { type: "submit" });

  const form = el(doc, "form", {}, [
    labelFor(doc, "phone", "Mobile number"),
    phoneInput,
    errorText,
    submitBtn,
  ]);
  doc.body.appendChild(form);

  submitBtn.addEventListener("click", function () {
    if (/^\+44\d{10}$/.test(phoneInput.value)) {
      doc.body.removeChild(form);
      doc.body.appendChild(el(doc, "div", {}, ["You're connected. Enjoy the WiFi."]));
      return;
    }
    phoneInput.setAttribute("aria-invalid", "true");
    errorText.textContent = "Please include the country code, e.g. +44.";
  });

  return { doc, identity: {phone: "07700900123"}, phoneInput: phoneInput };
}

module.exports = { build };
