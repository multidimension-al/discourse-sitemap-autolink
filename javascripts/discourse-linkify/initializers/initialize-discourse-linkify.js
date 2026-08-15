import { withPluginApi } from "discourse/lib/plugin-api";
import {
  isCategoryExcluded,
  linkifyElement,
  readInputList,
} from "../lib/utilities";

export default {
  name: "discourse-linkify-initializer",

  initialize() {
    withPluginApi((api) => {
      // roughly guided by https://stackoverflow.com/questions/8949445/javascript-bookmarklet-to-replace-text-with-a-link
      let skipTags = {
        a: 1,
        iframe: 1,
      };

      settings.excluded_tags.split("|").forEach((tag) => {
        tag = tag.trim().toLowerCase();
        if (tag !== "") {
          skipTags[tag] = 1;
        }
      });

      let skipClasses = {};

      settings.excluded_classes.split("|").forEach((cls) => {
        cls = cls.trim().toLowerCase();
        if (cls !== "") {
          skipClasses[cls] = 1;
        }
      });

      let createLink = function (text, url) {
        let link = document.createElement("a");
        link.textContent = text;
        link.href = url;
        link.rel = "nofollow";
        link.target = "_blank";
        link.className = "linkify-word no-track-link";
        return link;
      };

      let Action = function (inputListName, method) {
        this.inputListName = inputListName;
        this.createNode = method;
        this.inputs = {};
      };

      let linkify = new Action("linked_words", createLink);
      let actions = [linkify];
      actions.forEach(readInputList);

      const limits = {
        maxPerTerm: settings.max_links_per_term_per_post,
        maxTotal: settings.max_links_per_post,
      };

      const excludedCategoryIds = new Set(
        settings.excluded_category_ids
          .split("|")
          .map((id) => parseInt(id.trim(), 10))
          .filter((id) => !isNaN(id))
      );

      let categoriesById = null;
      const inExcludedCategory = (helper) => {
        if (excludedCategoryIds.size === 0) {
          return false;
        }
        const categoryId = helper?.getModel?.()?.topic?.category_id;
        if (!categoryId) {
          return false;
        }
        if (categoriesById === null) {
          const site = api.container.lookup("service:site");
          categoriesById = new Map(
            (site?.categories || []).map((c) => [c.id, c])
          );
        }
        return isCategoryExcluded(
          categoryId,
          excludedCategoryIds,
          categoriesById
        );
      };

      api.decorateCookedElement(
        (element, helper) => {
          if (inExcludedCategory(helper)) {
            return;
          }
          linkifyElement(element, actions, skipTags, skipClasses, limits);
        },
        { id: "linkify-words-theme" }
      );
    });
  },
};
