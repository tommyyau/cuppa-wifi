"use strict";

/**
 * Minimal hand-rolled DOM implementation, built for one purpose: giving
 * macos/Resources/autofill.js's DOM-facing functions (chooseForm,
 * fillOneStep, waitForStepOutcome, run, ...) real Element/Document
 * objects to operate on under plain Node — no jsdom/happy-dom, no npm
 * dependencies (none exist in this repo; tests run via
 * `node macos/Resources/__tests__/autofill.test.js`).
 *
 * Deliberately supports only what autofill.js actually touches: a small
 * CSS-selector subset (tag, [attr], [attr="value"], comma lists),
 * getAttribute/setAttribute, a real prototype chain so
 * Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")
 * resolves the way autofill.js's nativeSetterFor() expects (the
 * React-safe-set trick this file exists to test), bubbling
 * addEventListener/dispatchEvent, and a light checkValidity().
 *
 * Fixtures build documents by calling doc.createElement(...) directly —
 * there is no HTML-string parser here, so what you build is exactly
 * what autofill.js sees, no parsing ambiguity.
 */

function EventTargetMixin() {
  this._listeners = Object.create(null);
}
EventTargetMixin.prototype.addEventListener = function (type, handler) {
  (this._listeners[type] = this._listeners[type] || []).push(handler);
};
EventTargetMixin.prototype.removeEventListener = function (type, handler) {
  var list = this._listeners[type];
  if (!list) return;
  var idx = list.indexOf(handler);
  if (idx !== -1) list.splice(idx, 1);
};
EventTargetMixin.prototype.dispatchEvent = function (event) {
  event.target = event.target || this;
  var node = this;
  while (node) {
    event.currentTarget = node;
    var list = node._listeners && node._listeners[event.type];
    if (list) {
      list.slice().forEach(function (fn) {
        fn.call(node, event);
      });
    }
    if (!event.bubbles) break;
    node = node.parentNode || null;
  }
  return !event.defaultPrevented;
};

function DomEvent(type, opts) {
  opts = opts || {};
  this.type = type;
  this.bubbles = !!opts.bubbles;
  this.defaultPrevented = false;
  this.target = null;
  this.currentTarget = null;
}
DomEvent.prototype.preventDefault = function () {
  this.defaultPrevented = true;
};

function MutationObserverStub(cb) {
  this._cb = cb;
}
MutationObserverStub.prototype.observe = function () {};
MutationObserverStub.prototype.disconnect = function () {};

function DomNode() {
  EventTargetMixin.call(this);
  this.childNodes = [];
  this.parentNode = null;
}
DomNode.prototype = Object.create(EventTargetMixin.prototype);
DomNode.prototype.appendChild = function (child) {
  child.parentNode = this;
  this.childNodes.push(child);
  return child;
};
DomNode.prototype.removeChild = function (child) {
  var idx = this.childNodes.indexOf(child);
  if (idx !== -1) {
    this.childNodes.splice(idx, 1);
    child.parentNode = null;
  }
  return child;
};
Object.defineProperty(DomNode.prototype, "parentElement", {
  get: function () {
    return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null;
  },
});
Object.defineProperty(DomNode.prototype, "previousSibling", {
  get: function () {
    if (!this.parentNode) return null;
    var idx = this.parentNode.childNodes.indexOf(this);
    return idx > 0 ? this.parentNode.childNodes[idx - 1] : null;
  },
});

function TextNode(text) {
  DomNode.call(this);
  this.nodeType = 3;
  this.textContent = text;
}
TextNode.prototype = Object.create(DomNode.prototype);

function parseSimpleSelector(sel) {
  sel = sel.trim();
  var m = /^([a-zA-Z*]*)((?:\.[a-zA-Z0-9_-]+)*)((?:\[[^\]]+\])*)$/.exec(sel);
  if (!m) return null;
  var tag = m[1] ? m[1].toUpperCase() : null;
  var classes = m[2] ? m[2].slice(1).split('.') : [];
  var attrPart = m[3] || "";
  var attrs = [];
  var attrRe = /\[([a-zA-Z0-9_-]+)(?:=("([^"]*)"|'([^']*)'|[^\]]*))?\]/g;
  var am;
  while ((am = attrRe.exec(attrPart))) {
    var name = am[1];
    var value = am[3] !== undefined ? am[3] : am[4] !== undefined ? am[4] : am[2];
    attrs.push({ name: name, value: value === undefined ? undefined : value });
  }
  return { tag: tag, classes: classes, attrs: attrs };
}

function matchesSimple(el, simple) {
  if (el.nodeType !== 1) return false;
  if (simple.classes && !simple.classes.every(function (name) {
    return (el.getAttribute('class') || '').split(/\s+/).includes(name);
  })) return false;
  if (simple.tag && simple.tag !== "*" && el.tagName !== simple.tag) return false;
  for (var i = 0; i < simple.attrs.length; i++) {
    var a = simple.attrs[i];
    if (!el.hasAttribute(a.name)) return false;
    if (a.value !== undefined && el.getAttribute(a.name) !== a.value) return false;
  }
  return true;
}

function queryAll(root, selector) {
  var parts = selector
    .split(",")
    .map(function (s) {
      return parseSimpleSelector(s);
    })
    .filter(Boolean);
  var out = [];
  (function walk(node) {
    node.childNodes.forEach(function (c) {
      if (c.nodeType === 1) {
        for (var i = 0; i < parts.length; i++) {
          if (matchesSimple(c, parts[i])) {
            out.push(c);
            break;
          }
        }
        walk(c);
      }
    });
  })(root);
  return out;
}

function DomElement(tagName) {
  DomNode.call(this);
  this.nodeType = 1;
  this.tagName = tagName.toUpperCase();
  this._attrs = Object.create(null);
  this.ownerDocument = null;
}
DomElement.prototype = Object.create(DomNode.prototype);
DomElement.prototype.setAttribute = function (name, value) {
  this._attrs[name.toLowerCase()] = String(value);
};
DomElement.prototype.getAttribute = function (name) {
  var v = this._attrs[name.toLowerCase()];
  return v === undefined ? null : v;
};
DomElement.prototype.removeAttribute = function (name) {
  delete this._attrs[name.toLowerCase()];
};
DomElement.prototype.hasAttribute = function (name) {
  return this._attrs[name.toLowerCase()] !== undefined;
};
Object.defineProperty(DomElement.prototype, "id", {
  get: function () {
    return this.getAttribute("id") || "";
  },
  set: function (v) {
    this.setAttribute("id", v);
  },
});
Object.defineProperty(DomElement.prototype, "className", {
  get: function () {
    return this.getAttribute("class") || "";
  },
  set: function (v) {
    this.setAttribute("class", v);
  },
});
Object.defineProperty(DomElement.prototype, "hidden", {
  get: function () {
    return this.hasAttribute("hidden");
  },
  set: function (v) {
    v ? this.setAttribute("hidden", "") : this.removeAttribute("hidden");
  },
});
Object.defineProperty(DomElement.prototype, "textContent", {
  get: function () {
    return this.childNodes
      .map(function (c) {
        return c.textContent || "";
      })
      .join("");
  },
  set: function (v) {
    this.childNodes = [];
    this.appendChild(new TextNode(String(v)));
  },
});
Object.defineProperty(DomElement.prototype, "innerText", {
  get: function () {
    return this.textContent;
  },
  set: function (v) {
    this.textContent = v;
  },
});
DomElement.prototype.click = function () {
  this.dispatchEvent(new DomEvent("click", { bubbles: true }));
};
DomElement.prototype.querySelectorAll = function (selector) {
  return queryAll(this, selector);
};
DomElement.prototype.querySelector = function (selector) {
  return queryAll(this, selector)[0] || null;
};
DomElement.prototype.getElementsByTagName = function (tag) {
  var out = [];
  (function walk(node) {
    node.childNodes.forEach(function (c) {
      if (c.nodeType === 1) {
        if (tag === "*" || c.tagName === tag.toUpperCase()) out.push(c);
        walk(c);
      }
    });
  })(this);
  return out;
};

function boolAttrProperty(name) {
  return {
    get: function () {
      return this.hasAttribute(name);
    },
    set: function (v) {
      v ? this.setAttribute(name, "") : this.removeAttribute(name);
    },
  };
}

// ---- form-control elements -------------------------------------------

function HTMLInputElement() {
  DomElement.call(this, "input");
  this._value = "";
  this.checked = false;
}
HTMLInputElement.prototype = Object.create(DomElement.prototype);
Object.defineProperty(HTMLInputElement.prototype, "value", {
  get: function () {
    return this._value;
  },
  set: function (v) {
    this._value = String(v);
  },
});
Object.defineProperty(HTMLInputElement.prototype, "type", {
  get: function () {
    return (this.getAttribute("type") || "text").toLowerCase();
  },
  set: function (v) {
    this.setAttribute("type", v);
  },
});
Object.defineProperty(HTMLInputElement.prototype, "disabled", boolAttrProperty("disabled"));
Object.defineProperty(HTMLInputElement.prototype, "required", boolAttrProperty("required"));
Object.defineProperty(HTMLInputElement.prototype, "readOnly", {
  get: function () {
    return this.hasAttribute("readonly");
  },
  set: function (v) {
    v ? this.setAttribute("readonly", "") : this.removeAttribute("readonly");
  },
});
Object.defineProperty(HTMLInputElement.prototype, "maxLength", {
  get: function () {
    var v = this.getAttribute("maxlength");
    return v ? parseInt(v, 10) : -1;
  },
  set: function (v) {
    this.setAttribute("maxlength", v);
  },
});
HTMLInputElement.prototype.checkValidity = function () {
  var value = this.value || "";
  if (this.required && !value) return false;
  var pattern = this.getAttribute("pattern");
  if (pattern && value) {
    try {
      if (!new RegExp("^(?:" + pattern + ")$").test(value)) return false;
    } catch (e) {
      /* malformed pattern: don't fail validity over it */
    }
  }
  if (this.type === "email" && value && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) return false;
  return true;
};
Object.defineProperty(HTMLInputElement.prototype, "validationMessage", {
  get: function () {
    return this.checkValidity() ? "" : "Invalid value";
  },
});

function HTMLTextAreaElement() {
  DomElement.call(this, "textarea");
  this._value = "";
}
HTMLTextAreaElement.prototype = Object.create(DomElement.prototype);
Object.defineProperty(HTMLTextAreaElement.prototype, "value", {
  get: function () {
    return this._value;
  },
  set: function (v) {
    this._value = String(v);
  },
});
Object.defineProperty(HTMLTextAreaElement.prototype, "disabled", boolAttrProperty("disabled"));
Object.defineProperty(HTMLTextAreaElement.prototype, "required", boolAttrProperty("required"));
HTMLTextAreaElement.prototype.checkValidity = function () {
  return !(this.required && !this.value);
};
Object.defineProperty(HTMLTextAreaElement.prototype, "validationMessage", {
  get: function () {
    return this.checkValidity() ? "" : "Invalid value";
  },
});

function HTMLOptionElement() {
  DomElement.call(this, "option");
  this.selected = false;
}
HTMLOptionElement.prototype = Object.create(DomElement.prototype);
Object.defineProperty(HTMLOptionElement.prototype, "value", {
  get: function () {
    return this.hasAttribute("value") ? this.getAttribute("value") : this.textContent;
  },
  set: function (v) {
    this.setAttribute("value", v);
  },
});
Object.defineProperty(HTMLOptionElement.prototype, "disabled", boolAttrProperty("disabled"));

function HTMLSelectElement() {
  DomElement.call(this, "select");
}
HTMLSelectElement.prototype = Object.create(DomElement.prototype);
Object.defineProperty(HTMLSelectElement.prototype, "value", {
  get: function () {
    var opts = this.querySelectorAll("option");
    for (var i = 0; i < opts.length; i++) {
      if (opts[i].selected) return opts[i].value;
    }
    return opts.length ? opts[0].value : "";
  },
  set: function (v) {
    var opts = this.querySelectorAll("option");
    for (var i = 0; i < opts.length; i++) {
      opts[i].selected = opts[i].value === String(v);
    }
  },
});
Object.defineProperty(HTMLSelectElement.prototype, "disabled", boolAttrProperty("disabled"));
Object.defineProperty(HTMLSelectElement.prototype, "required", boolAttrProperty("required"));
HTMLSelectElement.prototype.checkValidity = function () {
  return !(this.required && !this.value);
};
Object.defineProperty(HTMLSelectElement.prototype, "validationMessage", {
  get: function () {
    return this.checkValidity() ? "" : "Invalid value";
  },
});

// ---- generic elements (form, button, label, div, span, a, ...) -------

function GenericElement(tag) {
  DomElement.call(this, tag);
}
GenericElement.prototype = Object.create(DomElement.prototype);
Object.defineProperty(GenericElement.prototype, "disabled", boolAttrProperty("disabled"));
Object.defineProperty(GenericElement.prototype, "value", {
  get: function () {
    return this.getAttribute("value") || "";
  },
  set: function (v) {
    this.setAttribute("value", v);
  },
});

// ---- document / window ------------------------------------------------

function Document() {
  DomNode.call(this);
  this.nodeType = 9;
  this.readyState = "complete";
  this.title = "";
  this.documentElement = new GenericElement("html");
  this.documentElement.ownerDocument = this;
  this.body = new GenericElement("body");
  this.body.ownerDocument = this;
  this.documentElement.appendChild(this.body);
  this.appendChild(this.documentElement);
  this.defaultView = null;
}
Document.prototype = Object.create(DomNode.prototype);
Document.prototype.createElement = function (tag) {
  tag = tag.toLowerCase();
  var el;
  if (tag === "input") el = new HTMLInputElement();
  else if (tag === "select") el = new HTMLSelectElement();
  else if (tag === "option") el = new HTMLOptionElement();
  else if (tag === "textarea") el = new HTMLTextAreaElement();
  else el = new GenericElement(tag);
  el.ownerDocument = this;
  return el;
};
Document.prototype.createTextNode = function (text) {
  return new TextNode(text);
};
Document.prototype.getElementById = function (id) {
  var found = null;
  (function walk(node) {
    if (found) return;
    node.childNodes.forEach(function (c) {
      if (found) return;
      if (c.nodeType === 1) {
        if (c.id === id) {
          found = c;
          return;
        }
        walk(c);
      }
    });
  })(this);
  return found;
};
Document.prototype.getElementsByTagName = DomElement.prototype.getElementsByTagName;
Document.prototype.querySelectorAll = function (selector) {
  return queryAll(this, selector);
};
Document.prototype.querySelector = function (selector) {
  return queryAll(this, selector)[0] || null;
};

function Window(doc) {
  EventTargetMixin.call(this);
  this.document = doc;
  this.HTMLInputElement = HTMLInputElement;
  this.HTMLSelectElement = HTMLSelectElement;
  this.HTMLTextAreaElement = HTMLTextAreaElement;
  this.HTMLOptionElement = HTMLOptionElement;
  this.Event = DomEvent;
  this.MutationObserver = MutationObserverStub;
}
Window.prototype = Object.create(EventTargetMixin.prototype);
Window.prototype.getComputedStyle = function (el) {
  var style = el.getAttribute("style") || "";
  return {
    display: /display\s*:\s*none/i.test(style) ? "none" : "",
    visibility: /visibility\s*:\s*hidden/i.test(style) ? "hidden" : "",
  };
};

function createDocument() {
  var doc = new Document();
  var win = new Window(doc);
  doc.defaultView = win;
  return doc;
}

module.exports = {
  createDocument: createDocument,
  Event: DomEvent,
};
