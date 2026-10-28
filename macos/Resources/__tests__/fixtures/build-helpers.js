"use strict";

/**
 * Small DOM-construction helpers on top of dom-shim.js, used by the
 * feedback-retry-loop fixtures. Keeps each fixture file focused on the
 * portal scenario it simulates rather than boilerplate node wiring.
 */

function el(doc, tag, attrs, children) {
  var node = doc.createElement(tag);
  attrs = attrs || {};
  Object.keys(attrs).forEach(function (key) {
    var value = attrs[key];
    if (value === undefined || value === null) return;
    if (key === "value" && (tag === "input" || tag === "textarea" || tag === "select" || tag === "option")) {
      node.value = value;
      // Also reflect as an attribute for <option> so value-vs-text
      // lookups in autofill.js (which read the attribute) still work.
      if (tag === "option") node.setAttribute("value", value);
      return;
    }
    if (key === "checked") {
      node.checked = !!value;
      return;
    }
    if (key === "selected") {
      node.selected = !!value;
      return;
    }
    node.setAttribute(key, value);
  });
  (children || []).forEach(function (child) {
    if (typeof child === "string") {
      node.appendChild(doc.createTextNode(child));
    } else if (child) {
      node.appendChild(child);
    }
  });
  return node;
}

function text(doc, str) {
  return doc.createTextNode(str);
}

function labelFor(doc, forId, labelText) {
  return el(doc, "label", { for: forId }, [labelText]);
}

function button(doc, buttonText, attrs) {
  return el(doc, "button", attrs, [buttonText]);
}

function option(doc, value, optionText, attrs) {
  var merged = Object.assign({ value: value }, attrs || {});
  return el(doc, "option", merged, [optionText]);
}

module.exports = {
  el: el,
  text: text,
  labelFor: labelFor,
  button: button,
  option: option,
};
