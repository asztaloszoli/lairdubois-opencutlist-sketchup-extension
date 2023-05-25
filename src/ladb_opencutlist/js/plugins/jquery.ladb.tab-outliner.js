+function ($) {
    'use strict';

    // CLASS DEFINITION
    // ======================

    var LadbTabOutliner = function (element, options, opencutlist) {
        LadbAbstractTab.call(this, element, options, opencutlist);

        this.editedNode = null;
        this.lastEditNodeTab = null;

        this.$header = $('.ladb-header', this.$element);
        this.$fileTabs = $('.ladb-file-tabs', this.$header);
        this.$btnGenerate = $('#ladb_btn_generate', this.$header);

        this.$page = $('.ladb-page', this.$element);

    };
    LadbTabOutliner.prototype = new LadbAbstractTab;

    LadbTabOutliner.DEFAULTS = {};

    // List /////

    LadbTabOutliner.prototype.generateOutliner = function (callback) {
        var that = this;

        this.materials = [];
        this.$page.empty();
        this.$btnGenerate.prop('disabled', true);
        this.setObsolete(false);

        window.requestAnimationFrame(function () {

            // Start progress feedback
            that.dialog.startProgress(1);

            rubyCallCommand('outliner_generate', {}, function (response) {

                var errors = response.errors;
                var warnings = response.warnings;
                var tips = response.tips;
                var filename = response.filename;
                var modelName = response.model_name;
                var root_node = response.root_node;

                // Keep useful data
                that.rootNode = root_node;

                // Update filename
                that.$fileTabs.empty();
                that.$fileTabs.append(Twig.twig({ ref: "tabs/outliner/_file-tab.twig" }).render({
                    filename: filename,
                    modelName: modelName
                }));

                // Update page
                that.$page.empty();
                that.$page.append(Twig.twig({ ref: "tabs/outliner/_list.twig" }).render({
                    errors: errors,
                    warnings: warnings,
                    tips: tips,
                    root_node: root_node
                }));

                // Setup tooltips
                that.dialog.setupTooltips();

                // Bind rows
                $('.ladb-outliner-row', that.$page).each(function (index) {
                    var $row = $(this);
                    $row.on('click', function (e) {
                        $(this).blur();
                        $('.ladb-click-tool', $(this)).click();
                        return false;
                    });
                });
                $('a.ladb-btn-folding-toggle-row', that.$page).on('click', function () {
                    $(this).blur();
                    var $row = $(this).parents('.ladb-outliner-row');
                    that.toggleFoldingRow($row);
                    return false;
                });
                $('a.ladb-btn-node-set-active', that.$page).on('click', function () {
                    $(this).blur();
                    var $row = $(this).parents('.ladb-outliner-row');
                    var nodeId = $row.data('node-id');

                    rubyCallCommand('outliner_set_active', { id: nodeId }, function (response) {

                        if (response['errors']) {
                            that.dialog.notifyErrors(response['errors']);
                        } else {

                        }

                    });

                    return false;
                });
                $('a.ladb-btn-node-toggle-visible', that.$page).on('click', function () {
                    $(this).blur();
                    var $row = $(this).parents('.ladb-outliner-row');
                    var nodeId = $row.data('node-id');

                    rubyCallCommand('outliner_toggle_visible', { id: nodeId }, function (response) {

                        if (response['errors']) {
                            that.dialog.notifyErrors(response['errors']);
                        } else {

                            if (response.visible) {
                                $row.removeClass('ladb-mute');
                            } else {
                                $row.addClass('ladb-mute');
                            }

                        }

                    });

                    return false;
                });
                $('a.ladb-btn-node-edit', that.$page).on('click', function () {
                    $(this).blur();
                    var $row = $(this).parents('.ladb-outliner-row');
                    var nodeId = $row.data('node-id');
                    that.editNode(nodeId);
                    return false;
                });

                // Restore button state
                that.$btnGenerate.prop('disabled', false);

                // Stick header
                that.stickSlideHeader(that.$rootSlide);

                // Finish progress feedback
                that.dialog.finishProgress();

                // Callback
                if (typeof callback === 'function') {
                    callback();
                }

            });

        });

    };

    LadbTabOutliner.prototype.editNode = function (id, tab) {
        var that = this;

        var node = this.findNodeById(id);
        if (node) {

            if (tab === undefined) {
                tab = this.lastEditNodeTab;
            }
            if (tab === null || tab.length === 0) {
                tab = 'general';
            }
            this.lastEditNodeTab = tab;

            // Keep the edited node
            this.editedNode = node;

            var $modal = this.appendModalInside('ladb_outliner_modal_edit', 'tabs/outliner/_modal-edit.twig', {
                capabilities: that.dialog.capabilities,
                mass_unit_strippedname: that.massUnitStrippedname,
                length_unit_strippedname: that.lengthUnitStrippedname,
                node: node,
                tab: tab,
            });

            // Fetch UI elements
            var $tabs = $('.modal-header a[data-toggle="tab"]', $modal);
            var $inputName = $('#ladb_outliner_node_input_name', $modal);
            var $inputDefinitionName = $('#ladb_outliner_node_input_definition_name', $modal);
            var $inputLayerName = $('#ladb_outliner_node_input_layer_name', $modal);
            var $btnExplode = $('#ladb_outliner_node_explode', $modal);
            var $btnUpdate = $('#ladb_outliner_node_update', $modal);

            // Bind tabs
            $tabs.on('shown.bs.tab', function (e) {
                that.lastEditNodeTab = $(e.target).attr('href').substring('#tab_edit_node_'.length);
            });

            // Bind input
            $inputName.ladbTextinputText();
            $inputDefinitionName.ladbTextinputText();
            $inputLayerName.ladbTextinputText();

            // Bind buttons
            $btnExplode.on('click', function () {

                var names = [];
                if (that.editedNode.name) {
                    names.push(that.editedNode.name);
                }
                if (that.editedNode.definition_name) {
                    var definitionName = that.editedNode.definition_name
                    if (that.editedNode.type === 2 || that.editedNode.type === 3) {   // 2 = TYPE_COMPONENT, 3 = TYPE_PART
                        definitionName = '<' + definitionName + '>'
                    }
                    names.push(definitionName);
                }

                that.dialog.confirm(i18next.t('default.caution'), i18next.t('tab.outliner.edit_node.explode_message', { name: names.join(' ') }), function () {

                    rubyCallCommand('outliner_explode', that.editedNode, function (response) {

                        if (response['errors']) {
                            that.dialog.notifyErrors(response['errors']);
                        } else {

                            // Reload the list
                            that.generateOutliner();

                            // Reset edited material
                            that.editedNode = null;

                            // Hide modal
                            $modal.modal('hide');

                        }

                    });

                }, {
                    confirmBtnType: 'danger',
                    confirmBtnLabel: i18next.t('tab.outliner.edit_node.explode')
                });

            });
            $btnUpdate.on('click', function () {

                that.editedNode.name = $inputName.val();
                that.editedNode.definition_name = $inputDefinitionName.val();
                that.editedNode.layer_name = $inputLayerName.val();

                rubyCallCommand('outliner_update', that.editedNode, function (response) {

                    if (response['errors']) {
                        that.dialog.notifyErrors(response['errors']);
                    } else {

                        // Reload the list
                        var nodeId = that.editedNode.id;
                        that.generateOutliner(function() {
                            that.scrollSlideToTarget(null, $('[data-node-id=' + nodeId + ']', that.$page), false, true);
                        });

                        // Reset edited material
                        that.editedNode = null;

                        // Hide modal
                        $modal.modal('hide');

                    }

                });

            });

            // Show modal
            $modal.modal('show');

            // Setup tooltips & popovers
            this.dialog.setupTooltips();
            this.dialog.setupPopovers();

        } else {
            alert('Node not found (id=' + id + ')');
        }

    };

    LadbTabOutliner.prototype.explodeNode = function(id) {
        var that = this;

        this.dialog.confirm(i18next.t('default.caution'), i18next.t('tab.outliner.explode.message', { id: id }), function () {

            rubyCallCommand('outliner_explode', {
                id: id,
            }, function (response) {

                if (response.errors && response.errors.length > 0) {
                    that.dialog.notifyErrors(response.errors);
                } else {

                    // Reload the list
                    that.generateOutliner();

                }

            });

        }, {
            confirmBtnType: 'danger',
            confirmBtnLabel: i18next.t('tab.outliner.edit_node.explode')
        });

    };
    LadbTabOutliner.prototype.toggleFoldingRow = function ($row, dataKey) {
        var $btn = $('.ladb-btn-folding-toggle-row', $row);
        var $i = $('i', $btn);

        if ($i.hasClass('ladb-opencutlist-icon-arrow-right')) {
            this.expandFoldingRow($row, dataKey);
        } else {
            this.collapseFoldingRow($row, dataKey);
        }
    };

    LadbTabOutliner.prototype.expandFoldingRow = function ($row, dataKey) {
        var rowId = $row.data(dataKey ? dataKey : 'node-id');
        var $btn = $('.ladb-btn-folding-toggle-row', $row);
        var $i = $('i', $btn);

        $i.addClass('ladb-opencutlist-icon-arrow-down');
        $i.removeClass('ladb-opencutlist-icon-arrow-right');

        // Show children
        $row.siblings('tr.folder-' + rowId).removeClass('hide');

    };

    LadbTabOutliner.prototype.collapseFoldingRow = function ($row, dataKey) {
        var rowId = $row.data(dataKey ? dataKey : 'node-id');
        var $btn = $('.ladb-btn-folding-toggle-row', $row);
        var $i = $('i', $btn);

        $i.addClass('ladb-opencutlist-icon-arrow-right');
        $i.removeClass('ladb-opencutlist-icon-arrow-down');

        // Hide children
        $row.siblings('tr.folder-' + rowId).addClass('hide');

    };

    LadbTabOutliner.prototype.expandAllFoldingRows = function ($slide, dataKey) {
        var that = this;
        $('.ladb-cutlist-row-folder', $slide === undefined ? this.$page : $slide).each(function () {
            that.expandFoldingRow($(this), dataKey);
        });
    };

    LadbTabOutliner.prototype.collapseAllFoldingRows = function ($slide, dataKey) {
        var that = this;
        $('.ladb-cutlist-row-folder', $slide === undefined ? this.$page : $slide).each(function () {
            that.collapseFoldingRow($(this), dataKey);
        });
    };

    // Internals /////

    LadbTabOutliner.prototype.findNodeById = function (id, parent) {
        if (parent === undefined) {
            parent = this.rootNode;
        }
        if (parent.id === id) {
            return parent;
        }
        for (var i = 0; i < parent.children.length; i++) {
            var node = this.findNodeById(id, parent.children[i]);
            if (node) {
                return node;
            }
        }
        return null;
    };

    LadbTabOutliner.prototype.showObsolete = function (messageI18nKey, forced) {
        if (!this.isObsolete() || forced) {

            var that = this;

            // Set tab as obsolete
            this.setObsolete(true);

            var $modal = this.appendModalInside('ladb_outliner_modal_obsolete', 'tabs/outliner/_modal-obsolete.twig', {
                messageI18nKey: messageI18nKey
            });

            // Fetch UI elements
            var $btnGenerate = $('#ladb_outliner_obsolete_generate', $modal);

            // Bind buttons
            $btnGenerate.on('click', function () {
                $modal.modal('hide');
                that.generateOutliner();
            });

            // Show modal
            $modal.modal('show');

        }
    };

    // Init ///

    LadbTabOutliner.prototype.bind = function () {
        LadbAbstractTab.prototype.bind.call(this);

        var that = this;

        // Bind buttons
        this.$btnGenerate.on('click', function () {
            that.generateOutliner();
            this.blur();
        });

        // Events

        addEventCallback([ 'on_new_model', 'on_open_model', 'on_activate_model' ], function (params) {
            that.showObsolete('core.event.model_change', true);
        });

    };

    LadbTabOutliner.prototype.defaultInitializedCallback = function () {
        LadbAbstractTab.prototype.defaultInitializedCallback.call(this);

        this.generateOutliner();

    };

    // PLUGIN DEFINITION
    // =======================

    function Plugin(option, params) {
        return this.each(function () {
            var $this = $(this);
            var data = $this.data('ladb.tab.plugin');
            var options = $.extend({}, LadbTabOutliner.DEFAULTS, $this.data(), typeof option === 'object' && option);

            if (!data) {
                if (undefined === options.dialog) {
                    throw 'dialog option is mandatory.';
                }
                $this.data('ladb.tab.plugin', (data = new LadbTabOutliner(this, options, options.dialog)));
            }
            if (typeof option === 'string') {
                data[option].apply(data, Array.isArray(params) ? params : [ params ])
            } else {
                data.init(option.initializedCallback);
            }
        })
    }

    var old = $.fn.ladbTabOutliner;

    $.fn.ladbTabOutliner = Plugin;
    $.fn.ladbTabOutliner.Constructor = LadbTabOutliner;


    // NO CONFLICT
    // =================

    $.fn.ladbTabOutliner.noConflict = function () {
        $.fn.ladbTabOutliner = old;
        return this;
    }

}(jQuery);