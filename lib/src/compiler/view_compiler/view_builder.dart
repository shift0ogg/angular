import "package:angular2/src/core/change_detection/change_detection.dart"
    show ChangeDetectionStrategy, isDefaultChangeDetectionStrategy;
import "package:angular2/src/core/linker/view_type.dart" show ViewType;
import "package:angular2/src/core/metadata/view.dart" show ViewEncapsulation;

import "../compile_metadata.dart"
    show CompileIdentifierMetadata, CompileDirectiveMetadata;
import "../identifiers.dart" show Identifiers, identifierToken;
import "../style_compiler.dart" show StylesCompileResult;
import "../output/output_ast.dart" as o;
import "../template_ast.dart"
    show
        TemplateAst,
        TemplateAstVisitor,
        NgContentAst,
        EmbeddedTemplateAst,
        ElementAst,
        ReferenceAst,
        VariableAst,
        BoundEventAst,
        BoundElementPropertyAst,
        AttrAst,
        BoundTextAst,
        TextAst,
        DirectiveAst,
        BoundDirectivePropertyAst,
        templateVisitAll;
import "compile_element.dart" show CompileElement, CompileNode;
import "compile_view.dart" show CompileView;
import "constants.dart"
    show
        ViewConstructorVars,
        InjectMethodVars,
        DetectChangesVars,
        ViewTypeEnum,
        ViewEncapsulationEnum,
        ChangeDetectionStrategyEnum,
        ViewProperties;
import "util.dart"
    show getViewFactoryName, createFlatArray, createDiTokenExpression;

const IMPLICIT_TEMPLATE_VAR = "\$implicit";
const CLASS_ATTR = "class";
const STYLE_ATTR = "style";
var parentRenderNodeVar = o.variable("parentRenderNode");
var rootSelectorVar = o.variable("rootSelector");
var NOT_THROW_ON_CHANGES = o.not(o.importExpr(Identifiers.throwOnChanges));

// List of supported namespaces.
const _NAMESPACE_URIS = const {
  'xlink': 'http://www.w3.org/1999/xlink',
  'svg': 'http://www.w3.org/2000/svg',
  'xhtml': 'http://www.w3.org/1999/xhtml'
};

class ViewCompileDependency {
  CompileDirectiveMetadata comp;
  CompileIdentifierMetadata factoryPlaceholder;
  ViewCompileDependency(this.comp, this.factoryPlaceholder);
}

num buildView(
    CompileView view,
    List<TemplateAst> template,
    StylesCompileResult stylesCompileResult,
    List<ViewCompileDependency> targetDependencies) {
  var builderVisitor =
      new ViewBuilderVisitor(view, targetDependencies, stylesCompileResult);
  templateVisitAll(
      builderVisitor,
      template,
      view.declarationElement.hasRenderNode
          ? view.declarationElement.parent
          : view.declarationElement);
  return builderVisitor.nestedViewCount;
}

finishView(CompileView view, List<o.Statement> targetStatements) {
  view.afterNodes();
  createViewTopLevelStmts(view, targetStatements);
  view.nodes.forEach((node) {
    if (node is CompileElement && node.embeddedView != null) {
      finishView(node.embeddedView, targetStatements);
    }
  });
}

class ViewBuilderVisitor implements TemplateAstVisitor {
  CompileView view;
  List<ViewCompileDependency> targetDependencies;
  final StylesCompileResult stylesCompileResult;
  static Map<String, CompileIdentifierMetadata> tagNameToIdentifier;

  num nestedViewCount = 0;
  ViewBuilderVisitor(
      this.view, this.targetDependencies, this.stylesCompileResult) {
    tagNameToIdentifier ??= {
      'a': Identifiers.HTML_ANCHOR_ELEMENT,
      'area': Identifiers.HTML_AREA_ELEMENT,
      'audio': Identifiers.HTML_AUDIO_ELEMENT,
      'button': Identifiers.HTML_BUTTON_ELEMENT,
      'canvas': Identifiers.HTML_CANVAS_ELEMENT,
      'form': Identifiers.HTML_FORM_ELEMENT,
      'iframe': Identifiers.HTML_IFRAME_ELEMENT,
      'input': Identifiers.HTML_INPUT_ELEMENT,
      'image': Identifiers.HTML_IMAGE_ELEMENT,
      'media': Identifiers.HTML_MEDIA_ELEMENT,
      'menu': Identifiers.HTML_MENU_ELEMENT,
      'ol': Identifiers.HTML_OLIST_ELEMENT,
      'option': Identifiers.HTML_OPTION_ELEMENT,
      'col': Identifiers.HTML_TABLE_COL_ELEMENT,
      'row': Identifiers.HTML_TABLE_ROW_ELEMENT,
      'select': Identifiers.HTML_SELECT_ELEMENT,
      'table': Identifiers.HTML_TABLE_ELEMENT,
      'text': Identifiers.HTML_TEXT_NODE,
      'textarea': Identifiers.HTML_TEXTAREA_ELEMENT,
      'ul': Identifiers.HTML_ULIST_ELEMENT,
    };
  }

  bool _isRootNode(CompileElement parent) {
    return !identical(parent.view, this.view);
  }

  _addRootNodeAndProject(
      CompileNode node, num ngContentIndex, CompileElement parent) {
    var vcAppEl = (node is CompileElement && node.hasViewContainer)
        ? node.appElement
        : null;
    if (this._isRootNode(parent)) {
      // store appElement as root node only for ViewContainers
      if (view.viewType != ViewType.COMPONENT) {
        view.rootNodesOrAppElements.add(vcAppEl ?? node.renderNode);
      }
    } else if (parent.component != null && ngContentIndex != null) {
      parent.addContentNode(ngContentIndex, vcAppEl ?? node.renderNode);
    }
  }

  o.Expression _getParentRenderNode(CompileElement parent) {
    if (this._isRootNode(parent)) {
      if (identical(this.view.viewType, ViewType.COMPONENT)) {
        return parentRenderNodeVar;
      } else {
        // root node of an embedded/host view
        return o.NULL_EXPR;
      }
    } else {
      return parent.component != null &&
              !identical(parent.component.template.encapsulation,
                  ViewEncapsulation.Native)
          ? o.NULL_EXPR
          : parent.renderNode;
    }
  }

  dynamic visitBoundText(BoundTextAst ast, dynamic context) {
    CompileElement parent = context;
    return this._visitText(ast, "", ast.ngContentIndex, parent, isBound: true);
  }

  dynamic visitText(TextAst ast, dynamic context) {
    CompileElement parent = context;
    return this
        ._visitText(ast, ast.value, ast.ngContentIndex, parent, isBound: false);
  }

  o.Expression _visitText(
      TemplateAst ast, String value, num ngContentIndex, CompileElement parent,
      {bool isBound}) {
    var fieldName = '_text_${this.view.nodes.length}';
    var renderNode;
    // If Text field is bound, we need access to the renderNode beyond
    // createInternal method and write reference to class member.
    // Otherwise we can create a local variable and not baloon class prototype.
    if (isBound) {
      view.fields.add(new o.ClassField(fieldName,
          o.importType(Identifiers.HTML_TEXT_NODE), [o.StmtModifier.Private]));
      renderNode = new o.ReadClassMemberExpr(fieldName);
    } else {
      view.createMethod.addStmt(new o.DeclareVarStmt(
          fieldName,
          o
              .importExpr(Identifiers.HTML_TEXT_NODE)
              .instantiate([o.literal(value)]),
          o.importType(Identifiers.HTML_TEXT_NODE)));
      renderNode = new o.ReadVarExpr(fieldName);
    }
    var compileNode =
        new CompileNode(parent, view, this.view.nodes.length, renderNode, ast);
    var parentRenderNodeExpr = _getParentRenderNode(parent);
    if (isBound) {
      var createRenderNodeExpr = new o.ReadClassMemberExpr(fieldName).set(o
          .importExpr(Identifiers.HTML_TEXT_NODE)
          .instantiate([o.literal(value)]));
      view.nodes.add(compileNode);
      view.createMethod.addStmt(createRenderNodeExpr.toStmt());
    } else {
      view.nodes.add(compileNode);
    }
    if (parentRenderNodeExpr != null && parentRenderNodeExpr != o.NULL_EXPR) {
      // Write append code.
      view.createMethod.addStmt(
          parentRenderNodeExpr.callMethod('append', [renderNode]).toStmt());
    }
    if (view.genConfig.genDebugInfo) {
      view.createMethod.addStmt(
          createDbgElementCall(renderNode, view.nodes.length - 1, ast));
    }
    this._addRootNodeAndProject(compileNode, ngContentIndex, parent);
    return renderNode;
  }

  dynamic visitNgContent(NgContentAst ast, dynamic context) {
    CompileElement parent = context;
    // the projected nodes originate from a different view, so we don't

    // have debug information for them...
    this.view.createMethod.resetDebugInfo(null, ast);
    var parentRenderNode = this._getParentRenderNode(parent);
    var nodesExpression = ViewProperties.projectableNodes.key(
        o.literal(ast.index),
        new o.ArrayType(o.importType(view.genConfig.renderTypes.renderNode)));
    if (!identical(parentRenderNode, o.NULL_EXPR)) {
      this
          .view
          .createMethod
          .addStmt(ViewProperties.renderer.callMethod("projectNodes", [
            parentRenderNode,
            o
                .importExpr(Identifiers.flattenNestedViewRenderNodes)
                .callFn([nodesExpression])
          ]).toStmt());
    } else if (this._isRootNode(parent)) {
      if (!identical(this.view.viewType, ViewType.COMPONENT)) {
        // store root nodes only for embedded/host views
        this.view.rootNodesOrAppElements.add(nodesExpression);
      }
    } else {
      if (parent.component != null && ast.ngContentIndex != null) {
        parent.addContentNode(ast.ngContentIndex, nodesExpression);
      }
    }
    return null;
  }

  /// Returns strongly typed html elements to improve code generation.
  CompileIdentifierMetadata identifierFromTagName(String name) {
    var elementType = tagNameToIdentifier[name.toLowerCase()];
    elementType ??= Identifiers.HTML_ELEMENT;
    // TODO: classify as HtmlElement or SvgElement to improve further.
    return elementType;
  }

  dynamic visitElement(ElementAst ast, dynamic context) {
    CompileElement parent = context;
    var nodeIndex = view.nodes.length;
    var fieldName = '_el_${nodeIndex}';
    bool isHostRootView = nodeIndex == 0 && view.viewType == ViewType.HOST;
    var elementType = isHostRootView
        ? Identifiers.HTML_ELEMENT
        : identifierFromTagName(ast.name);
    view.fields.add(new o.ClassField(
        fieldName, o.importType(elementType), [o.StmtModifier.Private]));

    var debugContextExpr =
        this.view.createMethod.resetDebugInfoExpr(nodeIndex, ast);
    var createRenderNodeExpr;

    o.Expression tagNameExpr = o.literal(ast.name);
    bool isHtmlElement;
    if (isHostRootView) {
      createRenderNodeExpr = new o.InvokeMemberMethodExpr(
          'selectOrCreateHostElement',
          [tagNameExpr, rootSelectorVar, debugContextExpr]);
      view.createMethod.addStmt(
          new o.WriteClassMemberExpr(fieldName, createRenderNodeExpr).toStmt());
      isHtmlElement = false;
    } else {
      isHtmlElement = detectHtmlElementFromTagName(ast.name);
      var parentRenderNodeExpr = _getParentRenderNode(parent);
      // Create element or elementNS. AST encodes svg path element as @svg:path.
      if (ast.name.startsWith('@') && ast.name.contains(':')) {
        var nameParts = ast.name.substring(1).split(':');
        String ns = _NAMESPACE_URIS[nameParts[0]];
        createRenderNodeExpr = o
            .importExpr(Identifiers.HTML_DOCUMENT)
            .callMethod(
                'createElementNS', [o.literal(ns), o.literal(nameParts[1])]);
      } else {
        // No namespace just call [document.createElement].
        createRenderNodeExpr = o
            .importExpr(Identifiers.HTML_DOCUMENT)
            .callMethod('createElement', [tagNameExpr]);
      }
      view.createMethod.addStmt(
          new o.WriteClassMemberExpr(fieldName, createRenderNodeExpr).toStmt());

      if (view.component.template.encapsulation == ViewEncapsulation.Emulated) {
        // Set ng_content attribute for CSS shim.
        o.Expression shimAttributeExpr = new o.ReadClassMemberExpr(fieldName)
            .callMethod('setAttribute',
                [new o.ReadClassMemberExpr('shimCAttr'), o.literal('')]);
        view.createMethod.addStmt(shimAttributeExpr.toStmt());
      }

      if (parentRenderNodeExpr != null && parentRenderNodeExpr != o.NULL_EXPR) {
        // Write append code.
        view.createMethod.addStmt(parentRenderNodeExpr.callMethod(
            'append', [new o.ReadClassMemberExpr(fieldName)]).toStmt());
      }
      if (view.genConfig.genDebugInfo) {
        view.createMethod.addStmt(createDbgElementCall(
            new o.ReadClassMemberExpr(fieldName), view.nodes.length, ast));
      }
    }

    var renderNode = o.THIS_EXPR.prop(fieldName);

    var directives =
        ast.directives.map((directiveAst) => directiveAst.directive).toList();
    var component = directives.firstWhere((directive) => directive.isComponent,
        orElse: () => null);
    var htmlAttrs = _readHtmlAttrs(ast.attrs);
    var attrNameAndValues = _mergeHtmlAndDirectiveAttrs(htmlAttrs, directives);
    for (var i = 0; i < attrNameAndValues.length; i++) {
      var attrName = attrNameAndValues[i][0];
      var attrValue = attrNameAndValues[i][1];
      this.view.createMethod.addStmt(ViewProperties.renderer.callMethod(
          "setElementAttribute",
          [renderNode, o.literal(attrName), o.literal(attrValue)]).toStmt());
    }
    var compileElement = new CompileElement(
        parent,
        this.view,
        nodeIndex,
        renderNode,
        fieldName,
        ast,
        component,
        directives,
        ast.providers,
        ast.hasViewContainer,
        false,
        ast.references,
        isHtmlElement: isHtmlElement);
    this.view.nodes.add(compileElement);
    o.ReadVarExpr compViewExpr;
    if (component != null) {
      var nestedComponentIdentifier =
          new CompileIdentifierMetadata(name: getViewFactoryName(component, 0));
      this
          .targetDependencies
          .add(new ViewCompileDependency(component, nestedComponentIdentifier));
      compViewExpr = o.variable('compView_${nodeIndex}');
      compileElement.setComponentView(compViewExpr);
      this.view.createMethod.addStmt(compViewExpr
          .set(o.importExpr(nestedComponentIdentifier).callFn([
            ViewProperties.viewUtils,
            compileElement.injector,
            compileElement.appElement
          ]))
          .toDeclStmt());
    }
    compileElement.beforeChildren();
    this._addRootNodeAndProject(compileElement, ast.ngContentIndex, parent);
    templateVisitAll(this, ast.children, compileElement);
    compileElement.afterChildren(this.view.nodes.length - nodeIndex - 1);
    if (compViewExpr != null) {
      var codeGenContentNodes;
      if (this.view.component.type.isHost) {
        codeGenContentNodes = ViewProperties.projectableNodes;
      } else {
        codeGenContentNodes = o.literalArr(compileElement
            .contentNodesByNgContentIndex
            .map((nodes) => createFlatArray(nodes))
            .toList());
      }
      view.createMethod.addStmt(compViewExpr
          .callMethod("create", [codeGenContentNodes, o.NULL_EXPR]).toStmt());
    }
    return null;
  }

  o.Statement createDbgElementCall(
      o.Expression nodeExpr, int nodeIndex, TemplateAst ast) {
    var sourceLocation = ast?.sourceSpan?.start;
    return new o.InvokeMemberMethodExpr('dbgElm', [
      nodeExpr,
      o.literal(nodeIndex),
      sourceLocation == null ? o.NULL_EXPR : o.literal(sourceLocation.line),
      sourceLocation == null ? o.NULL_EXPR : o.literal(sourceLocation.col)
    ]).toStmt();
  }

  dynamic visitEmbeddedTemplate(EmbeddedTemplateAst ast, dynamic context) {
    CompileElement parent = context;
    var nodeIndex = this.view.nodes.length;
    var fieldName = '_anchor_${ nodeIndex}' '';
    this.view.fields.add(new o.ClassField(
        fieldName,
        o.importType(view.genConfig.renderTypes.renderComment),
        [o.StmtModifier.Private]));
    var debugContextExpr = view.createMethod.resetDebugInfoExpr(nodeIndex, ast);
    this.view.createMethod.addStmt(o.THIS_EXPR
        .prop(fieldName)
        .set(ViewProperties.renderer.callMethod("createTemplateAnchor",
            [this._getParentRenderNode(parent), debugContextExpr]))
        .toStmt());
    var renderNode = o.THIS_EXPR.prop(fieldName);
    var templateVariableBindings = ast.variables
        .map((varAst) => [
              varAst.value.length > 0 ? varAst.value : IMPLICIT_TEMPLATE_VAR,
              varAst.name
            ])
        .toList();
    var directives =
        ast.directives.map((directiveAst) => directiveAst.directive).toList();
    var compileElement = new CompileElement(
        parent,
        this.view,
        nodeIndex,
        renderNode,
        fieldName,
        ast,
        null,
        directives,
        ast.providers,
        ast.hasViewContainer,
        true,
        ast.references);
    this.view.nodes.add(compileElement);
    this.nestedViewCount++;
    var embeddedView = new CompileView(
        this.view.component,
        this.view.genConfig,
        this.view.pipeMetas,
        o.NULL_EXPR,
        this.view.viewIndex + this.nestedViewCount,
        compileElement,
        templateVariableBindings);
    this.nestedViewCount += buildView(embeddedView, ast.children,
        stylesCompileResult, this.targetDependencies);
    compileElement.beforeChildren();
    this._addRootNodeAndProject(compileElement, ast.ngContentIndex, parent);
    compileElement.afterChildren(0);
    return null;
  }

  dynamic visitAttr(AttrAst ast, dynamic ctx) {
    return null;
  }

  dynamic visitDirective(DirectiveAst ast, dynamic ctx) {
    return null;
  }

  dynamic visitEvent(BoundEventAst ast, dynamic context) {
    return null;
  }

  dynamic visitReference(ReferenceAst ast, dynamic ctx) {
    return null;
  }

  dynamic visitVariable(VariableAst ast, dynamic ctx) {
    return null;
  }

  dynamic visitDirectiveProperty(
      BoundDirectivePropertyAst ast, dynamic context) {
    return null;
  }

  dynamic visitElementProperty(BoundElementPropertyAst ast, dynamic context) {
    return null;
  }
}

List<List<String>> _mergeHtmlAndDirectiveAttrs(
    Map<String, String> declaredHtmlAttrs,
    List<CompileDirectiveMetadata> directives) {
  Map<String, String> result = {};
  declaredHtmlAttrs.forEach((key, value) => result[key] = value);
  directives.forEach((directiveMeta) {
    directiveMeta.hostAttributes.forEach((name, value) {
      var prevValue = result[name];
      result[name] = prevValue != null
          ? mergeAttributeValue(name, prevValue, value)
          : value;
    });
  });
  return mapToKeyValueArray(result);
}

Map<String, String> _readHtmlAttrs(List<AttrAst> attrs) {
  Map<String, String> htmlAttrs = {};
  attrs.forEach((ast) {
    htmlAttrs[ast.name] = ast.value;
  });
  return htmlAttrs;
}

String mergeAttributeValue(
    String attrName, String attrValue1, String attrValue2) {
  if (attrName == CLASS_ATTR || attrName == STYLE_ATTR) {
    return '''${ attrValue1} ${ attrValue2}''';
  } else {
    return attrValue2;
  }
}

List<List<String>> mapToKeyValueArray(Map<String, String> data) {
  var entryArray = [];
  data.forEach((name, value) {
    entryArray.add([name, value]);
  });
  // We need to sort to get a defined output order
  // for tests and for caching generated artifacts...
  entryArray.sort((entry1, entry2) => entry1[0].compareTo(entry2[0]));
  var keyValueArray = <List<String>>[];
  entryArray.forEach((entry) {
    keyValueArray.add([entry[0], entry[1]]);
  });
  return keyValueArray;
}

createViewTopLevelStmts(CompileView view, List<o.Statement> targetStatements) {
  o.Expression nodeDebugInfosVar = o.NULL_EXPR;
  if (view.genConfig.genDebugInfo) {
    // Create top level node debug info.
    // Example:
    // const List<StaticNodeDebugInfo> nodeDebugInfos_MyAppComponent0 = const [
    //     const StaticNodeDebugInfo(const [],null,const <String, dynamic>{}),
    //     const StaticNodeDebugInfo(const [],null,const <String, dynamic>{}),
    //     const StaticNodeDebugInfo(const [
    //       import1.AcxDarkTheme,
    //       import2.MaterialButtonComponent,
    //       import3.ButtonDirective
    //     ]
    //     ,import2.MaterialButtonComponent,const <String, dynamic>{}),
    // const StaticNodeDebugInfo(const [],null,const <String, dynamic>{}),
    // ...
    nodeDebugInfosVar = o.variable(
        'nodeDebugInfos_${view.component.type.name}${view.viewIndex}');
    targetStatements.add(((nodeDebugInfosVar as o.ReadVarExpr))
        .set(o.literalArr(
            view.nodes.map(createStaticNodeDebugInfo).toList(),
            new o.ArrayType(new o.ExternalType(Identifiers.StaticNodeDebugInfo),
                [o.TypeModifier.Const])))
        .toDeclStmt(null, [o.StmtModifier.Final]));
  }
  String renderTypeVarName = 'renderType_${view.component.type.name}';
  o.ReadVarExpr renderCompTypeVar = o.variable(renderTypeVarName);
  // If we are compiling root view, create a render type for the component.
  // Example: RenderComponentType renderType_MaterialButtonComponent;
  if (identical(view.viewIndex, 0)) {
    targetStatements.add(new o.DeclareVarStmt(renderTypeVarName, null,
        o.importType(Identifiers.RenderComponentType)));
  }
  var viewClass = createViewClass(view, renderCompTypeVar, nodeDebugInfosVar);
  targetStatements.add(viewClass);
  targetStatements.add(createViewFactory(view, viewClass, renderCompTypeVar));
}

o.Expression createStaticNodeDebugInfo(CompileNode node) {
  var compileElement = node is CompileElement ? node : null;
  List<o.Expression> providerTokens = [];
  o.Expression componentToken = o.NULL_EXPR;
  var varTokenEntries = <List>[];
  if (compileElement != null) {
    providerTokens = compileElement.getProviderTokens();
    if (compileElement.component != null) {
      componentToken = createDiTokenExpression(
          identifierToken(compileElement.component.type));
    }

    compileElement.referenceTokens?.forEach((String varName, token) {
      varTokenEntries.add([
        varName,
        token != null ? createDiTokenExpression(token) : o.NULL_EXPR
      ]);
    });
  }
  // Optimize StaticNodeDebugInfo(const [],null,const <String, dynamic>{}), case
  // by writing out null.
  if (providerTokens.isEmpty &&
      componentToken == o.NULL_EXPR &&
      varTokenEntries.isEmpty) {
    return o.NULL_EXPR;
  }
  return o.importExpr(Identifiers.StaticNodeDebugInfo).instantiate(
      [
        o.literalArr(providerTokens,
            new o.ArrayType(o.DYNAMIC_TYPE, [o.TypeModifier.Const])),
        componentToken,
        o.literalMap(varTokenEntries,
            new o.MapType(o.DYNAMIC_TYPE, [o.TypeModifier.Const]))
      ],
      o.importType(
          Identifiers.StaticNodeDebugInfo, null, [o.TypeModifier.Const]));
}

o.ClassStmt createViewClass(CompileView view, o.ReadVarExpr renderCompTypeVar,
    o.Expression nodeDebugInfosVar) {
  var emptyTemplateVariableBindings = view.templateVariableBindings
      .map((entry) => [entry[0], o.NULL_EXPR])
      .toList();
  var viewConstructorArgs = [
    new o.FnParam(ViewConstructorVars.viewUtils.name,
        o.importType(Identifiers.ViewUtils)),
    new o.FnParam(ViewConstructorVars.parentInjector.name,
        o.importType(Identifiers.Injector)),
    new o.FnParam(ViewConstructorVars.declarationEl.name,
        o.importType(Identifiers.AppElement))
  ];
  var superConstructorArgs = [
    o.variable(view.className),
    renderCompTypeVar,
    ViewTypeEnum.fromValue(view.viewType),
    o.literalMap(emptyTemplateVariableBindings),
    ViewConstructorVars.viewUtils,
    ViewConstructorVars.parentInjector,
    ViewConstructorVars.declarationEl,
    ChangeDetectionStrategyEnum.fromValue(getChangeDetectionMode(view))
  ];
  if (view.genConfig.genDebugInfo) {
    superConstructorArgs.add(nodeDebugInfosVar);
  }
  var viewConstructor = new o.ClassMethod(null, viewConstructorArgs,
      [o.SUPER_EXPR.callFn(superConstructorArgs).toStmt()]);
  var viewMethods = (new List.from([
    new o.ClassMethod(
        "createInternal",
        [new o.FnParam(rootSelectorVar.name, o.DYNAMIC_TYPE)],
        generateCreateMethod(view),
        o.importType(Identifiers.AppElement)),
    new o.ClassMethod(
        "injectorGetInternal",
        [
          new o.FnParam(InjectMethodVars.token.name, o.DYNAMIC_TYPE),
          // Note: Can't use o.INT_TYPE here as the method in AppView uses number
          new o.FnParam(InjectMethodVars.requestNodeIndex.name, o.NUMBER_TYPE),
          new o.FnParam(InjectMethodVars.notFoundResult.name, o.DYNAMIC_TYPE)
        ],
        addReturnValuefNotEmpty(
            view.injectorGetMethod.finish(), InjectMethodVars.notFoundResult),
        o.DYNAMIC_TYPE),
    new o.ClassMethod(
        "detectChangesInternal", [], generateDetectChangesMethod(view)),
    new o.ClassMethod("dirtyParentQueriesInternal", [],
        view.dirtyParentQueriesMethod.finish()),
    new o.ClassMethod("destroyInternal", [], view.destroyMethod.finish())
  ])..addAll(view.eventHandlerMethods));
  var superClass = view.genConfig.genDebugInfo
      ? Identifiers.DebugAppView
      : Identifiers.AppView;
  var viewClass = new o.ClassStmt(
      view.className,
      o.importExpr(superClass, [getContextType(view)]),
      view.fields,
      view.getters,
      viewConstructor,
      viewMethods
          .where((o.ClassMethod method) => method.body.length > 0)
          .toList() as List<o.ClassMethod>);
  return viewClass;
}

o.Statement createViewFactory(
    CompileView view, o.ClassStmt viewClass, o.ReadVarExpr renderCompTypeVar) {
  var viewFactoryArgs = [
    new o.FnParam(ViewConstructorVars.viewUtils.name,
        o.importType(Identifiers.ViewUtils)),
    new o.FnParam(ViewConstructorVars.parentInjector.name,
        o.importType(Identifiers.Injector)),
    new o.FnParam(ViewConstructorVars.declarationEl.name,
        o.importType(Identifiers.AppElement))
  ];
  var initRenderCompTypeStmts = [];
  var templateUrlInfo;
  if (view.component.template.templateUrl == view.component.type.moduleUrl) {
    templateUrlInfo = '${view.component.type.moduleUrl} '
        'class ${view.component.type.name} - inline template';
  } else {
    templateUrlInfo = view.component.template.templateUrl;
  }
  if (identical(view.viewIndex, 0)) {
    initRenderCompTypeStmts = [
      new o.IfStmt(renderCompTypeVar.identical(o.NULL_EXPR), [
        renderCompTypeVar
            .set(ViewConstructorVars.viewUtils
                .callMethod("createRenderComponentType", [
              o.literal(templateUrlInfo),
              o.literal(view.component.template.ngContentSelectors.length),
              ViewEncapsulationEnum
                  .fromValue(view.component.template.encapsulation),
              view.styles
            ]))
            .toStmt()
      ])
    ];
  }
  return o
      .fn(
          viewFactoryArgs,
          (new List.from(initRenderCompTypeStmts)
            ..addAll([
              new o.ReturnStatement(o.variable(viewClass.name).instantiate(
                  viewClass.constructorMethod.params
                      .map((param) => o.variable(param.name))
                      .toList()))
            ])),
          o.importType(Identifiers.AppView, [getContextType(view)]))
      .toDeclStmt(view.viewFactory.name, [o.StmtModifier.Final]);
}

List<o.Statement> generateCreateMethod(CompileView view) {
  o.Expression parentRenderNodeExpr = o.NULL_EXPR;
  var parentRenderNodeStmts = [];
  if (identical(view.viewType, ViewType.COMPONENT)) {
    if (view.component.template.encapsulation == ViewEncapsulation.Native) {
      parentRenderNodeExpr = new o.InvokeMemberMethodExpr(
          "createViewShadowRoot", [
        new o.ReadClassMemberExpr("declarationAppElement").prop("nativeElement")
      ]);
    } else {
      parentRenderNodeExpr = new o.InvokeMemberMethodExpr("initViewRoot",
          [o.THIS_EXPR.prop("declarationAppElement").prop("nativeElement")]);
    }
    parentRenderNodeStmts = [
      parentRenderNodeVar.set(parentRenderNodeExpr).toDeclStmt(
          o.importType(view.genConfig.renderTypes.renderNode),
          [o.StmtModifier.Final])
    ];
  }
  o.Expression resultExpr;
  if (identical(view.viewType, ViewType.HOST)) {
    resultExpr = ((view.nodes[0] as CompileElement)).appElement;
  } else {
    resultExpr = o.NULL_EXPR;
  }
  return (new List.from(
      (new List.from(parentRenderNodeStmts)
        ..addAll(view.createMethod.finish())))
    ..addAll([
      o.THIS_EXPR.callMethod("init", [
        createFlatArray(view.rootNodesOrAppElements),
        o.literalArr(view.nodes.map((node) {
          if (node is CompileElement) {
            return new o.ReadClassMemberExpr(node.renderNodeFieldName);
          } else
            return node.renderNode;
        }).toList()),
        o.literalArr(view.subscriptions)
      ]).toStmt(),
      new o.ReturnStatement(resultExpr)
    ]));
}

List<o.Statement> generateDetectChangesMethod(CompileView view) {
  var stmts = <o.Statement>[];
  if (view.detectChangesInInputsMethod.isEmpty() &&
      view.updateContentQueriesMethod.isEmpty() &&
      view.afterContentLifecycleCallbacksMethod.isEmpty() &&
      view.detectChangesRenderPropertiesMethod.isEmpty() &&
      view.updateViewQueriesMethod.isEmpty() &&
      view.afterViewLifecycleCallbacksMethod.isEmpty()) {
    return stmts;
  }
  stmts.addAll(view.detectChangesInInputsMethod.finish());
  stmts
      .add(o.THIS_EXPR.callMethod("detectContentChildrenChanges", []).toStmt());
  List<o.Statement> afterContentStmts =
      (new List.from(view.updateContentQueriesMethod.finish())
        ..addAll(view.afterContentLifecycleCallbacksMethod.finish()));
  if (afterContentStmts.length > 0) {
    stmts.add(new o.IfStmt(NOT_THROW_ON_CHANGES, afterContentStmts));
  }
  stmts.addAll(view.detectChangesRenderPropertiesMethod.finish());
  stmts.add(o.THIS_EXPR.callMethod("detectViewChildrenChanges", []).toStmt());
  List<o.Statement> afterViewStmts =
      (new List.from(view.updateViewQueriesMethod.finish())
        ..addAll(view.afterViewLifecycleCallbacksMethod.finish()));
  if (afterViewStmts.length > 0) {
    stmts.add(new o.IfStmt(NOT_THROW_ON_CHANGES, afterViewStmts));
  }
  var varStmts = [];
  var readVars = o.findReadVarNames(stmts);
  if (readVars.contains(DetectChangesVars.changed.name)) {
    varStmts.add(
        DetectChangesVars.changed.set(o.literal(true)).toDeclStmt(o.BOOL_TYPE));
  }
  if (readVars.contains(DetectChangesVars.changes.name)) {
    varStmts.add(new o.DeclareVarStmt(DetectChangesVars.changes.name, null,
        new o.MapType(o.importType(Identifiers.SimpleChange))));
  }
  if (readVars.contains(DetectChangesVars.valUnwrapper.name)) {
    varStmts.add(DetectChangesVars.valUnwrapper
        .set(o.importExpr(Identifiers.ValueUnwrapper).instantiate([]))
        .toDeclStmt(null, [o.StmtModifier.Final]));
  }
  return (new List.from(varStmts)..addAll(stmts));
}

List<o.Statement> addReturnValuefNotEmpty(
    List<o.Statement> statements, o.Expression value) {
  if (statements.length > 0) {
    return (new List.from(statements)..addAll([new o.ReturnStatement(value)]));
  } else {
    return statements;
  }
}

o.OutputType getContextType(CompileView view) {
  var typeMeta = view.component.type;
  return typeMeta.isHost ? o.DYNAMIC_TYPE : o.importType(typeMeta);
}

ChangeDetectionStrategy getChangeDetectionMode(CompileView view) {
  ChangeDetectionStrategy mode;
  if (identical(view.viewType, ViewType.COMPONENT)) {
    mode = isDefaultChangeDetectionStrategy(view.component.changeDetection)
        ? ChangeDetectionStrategy.CheckAlways
        : ChangeDetectionStrategy.CheckOnce;
  } else {
    mode = ChangeDetectionStrategy.CheckAlways;
  }
  return mode;
}

Set<String> tagNameSet;

/// Returns true if tag name is HtmlElement.
///
/// Returns false if tag name is svg element or other. Used for optimizations.
/// Should not generate false positives but returning false when unknown is
/// fine since code will fallback to general Element case.
bool detectHtmlElementFromTagName(String tagName) {
  const htmlTagNames = const <String>[
    'a',
    'abbr',
    'acronym',
    'address',
    'applet',
    'area',
    'article',
    'aside',
    'audio',
    'b',
    'base',
    'basefont',
    'bdi',
    'bdo',
    'bgsound',
    'big',
    'blockquote',
    'body',
    'br',
    'button',
    'canvas',
    'caption',
    'center',
    'cite',
    'code',
    'col',
    'colgroup',
    'command',
    'data',
    'datalist',
    'dd',
    'del',
    'details',
    'dfn',
    'dialog',
    'dir',
    'div',
    'dl',
    'dt',
    'element',
    'em',
    'embed',
    'fieldset',
    'figcaption',
    'figure',
    'font',
    'footer',
    'form',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'head',
    'header',
    'hr',
    'i',
    'iframe',
    'img',
    'input',
    'ins',
    'kbd',
    'keygen',
    'label',
    'legend',
    'li',
    'link',
    'listing',
    'main',
    'map',
    'mark',
    'menu',
    'menuitem',
    'meta',
    'meter',
    'nav',
    'object',
    'ol',
    'optgroup',
    'option',
    'output',
    'p',
    'param',
    'picture',
    'pre',
    'progress',
    'q',
    'rp',
    'rt',
    'rtc',
    'ruby',
    's',
    'samp',
    'script',
    'section',
    'select',
    'shadow',
    'small',
    'source',
    'span',
    'strong',
    'style',
    'sub',
    'summary',
    'sup',
    'table',
    'tbody',
    'td',
    'template',
    'textarea',
    'tfoot',
    'th',
    'thead',
    'time',
    'title',
    'tr',
    'track',
    'tt',
    'u',
    'ul',
    'var',
    'video',
    'wbr'
  ];
  if (tagNameSet == null) {
    tagNameSet = new Set<String>();
    for (String name in htmlTagNames) tagNameSet.add(name);
  }
  return tagNameSet.contains(tagName);
}
