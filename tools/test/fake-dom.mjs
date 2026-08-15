// Minimal DOM stand-in for exercising the linkify pipeline under Node.
// Implements just the surface utilities.js touches: childNodes, nodeType,
// nodeName, getAttribute, Text#splitText/nextSibling/parentNode and
// Element#replaceChild.

export class FakeText {
  nodeType = 3;

  constructor(data) {
    this.data = data;
    this.parentNode = null;
  }

  get nextSibling() {
    const siblings = this.parentNode.childNodes;
    const index = siblings.indexOf(this);
    return siblings[index + 1] ?? null;
  }

  splitText(offset) {
    const rest = new FakeText(this.data.slice(offset));
    this.data = this.data.slice(0, offset);
    const siblings = this.parentNode.childNodes;
    siblings.splice(siblings.indexOf(this) + 1, 0, rest);
    rest.parentNode = this.parentNode;
    return rest;
  }
}

export class FakeElement {
  nodeType = 1;

  constructor(tag, attrs = {}) {
    this.nodeName = tag.toUpperCase();
    this.attrs = { ...attrs };
    this.childNodes = [];
    this.parentNode = null;
  }

  getAttribute(name) {
    return name in this.attrs ? this.attrs[name] : null;
  }

  append(...children) {
    for (const child of children) {
      const node = typeof child === "string" ? new FakeText(child) : child;
      node.parentNode = this;
      this.childNodes.push(node);
    }
    return this;
  }

  replaceChild(newNode, oldNode) {
    const index = this.childNodes.indexOf(oldNode);
    if (index === -1) {
      throw new Error("replaceChild: node not found");
    }
    this.childNodes[index] = newNode;
    newNode.parentNode = this;
    oldNode.parentNode = null;
    return oldNode;
  }
}

export function el(tag, attrs, ...children) {
  return new FakeElement(tag, attrs ?? {}).append(...children);
}

export function serialize(node) {
  if (node.nodeType === 3) {
    return node.data;
  }
  const tag = node.nodeName.toLowerCase();
  const attrs = Object.entries(node.attrs)
    .map(([k, v]) => ` ${k}="${v}"`)
    .join("");
  const children = node.childNodes.map(serialize).join("");
  return `<${tag}${attrs}>${children}</${tag}>`;
}

// Collect all <a> descendants as {href, text} in document order.
export function linksIn(node) {
  const links = [];
  const walk = (n) => {
    if (n.nodeType !== 1) {
      return;
    }
    if (n.nodeName === "A") {
      links.push({
        href: n.getAttribute("href"),
        text: n.childNodes.map(serialize).join(""),
        class: n.getAttribute("class"),
      });
    }
    n.childNodes.forEach(walk);
  };
  walk(node);
  return links;
}
