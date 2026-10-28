"use strict";

/**
 * Provisional rendered Pret contract. It pins the WebView mechanism that
 * complements the static Pret contract until the next value-free live
 * capture replaces this fixture.
 */

const { createDocument } = require("./dom-shim");
const { el, labelFor, button } = require("./build-helpers");

function build() {
  const doc = createDocument();
  doc.title = "Pret A Manger Wi-Fi";

  const first = el(doc, "input", {
    id: "first",
    name: "first_name",
    required: "",
  });
  const last = el(doc, "input", {
    id: "last",
    name: "last_name",
    required: "",
  });
  const email = el(doc, "input", {
    id: "email",
    name: "email",
    type: "email",
    required: "",
  });
  const terms = el(doc, "input", {
    id: "terms",
    name: "terms",
    type: "checkbox",
    required: "",
  });
  const marketing = el(doc, "input", {
    id: "marketing",
    name: "marketing",
    type: "checkbox",
  });
  const submit = button(doc, "Get online", { type: "submit" });
  const form = el(doc, "form", {}, [
    el(doc, "h1", {}, ["Welcome to Pret"]),
    labelFor(doc, "first", "First name"),
    first,
    labelFor(doc, "last", "Last name"),
    last,
    labelFor(doc, "email", "Email address"),
    email,
    labelFor(doc, "terms", "Accept terms and conditions"),
    terms,
    labelFor(doc, "marketing", "Send Pret marketing offers"),
    marketing,
    submit,
  ]);
  doc.body.appendChild(form);

  let accepted = false;
  submit.addEventListener("click", function () {
    accepted =
      first.value === "Sarah" &&
      last.value === "Chen" &&
      email.value === "sarah.chen.fixture@example.com" &&
      terms.checked === true &&
      marketing.checked !== true;
    if (accepted) {
      doc.body.removeChild(form);
      doc.body.appendChild(el(doc, "div", {}, ["Connected"]));
    }
  });

  return {
    doc,
    identity: {
      firstName: "Sarah",
      lastName: "Chen",
      email: "sarah.chen.fixture@example.com",
    },
    fields: { first, last, email, terms, marketing },
    wasAccepted: () => accepted,
  };
}

module.exports = { build };
