module Ladb::OpenCutList

  require 'benchmark'
  require 'securerandom'
  require_relative '../../plugin'
  require_relative '../../helper/layer_visibility_helper'

  class CutlistLayoutToLayoutWorker

    include LayerVisibilityHelper

    def initialize(settings, cutlist)

      @parts_infos = settings.fetch('parts_infos', nil)
      @pins_infos = settings.fetch('pins_infos', nil)
      @target_group_id = settings.fetch('target_group_id', nil)

      @generated_at = settings.fetch('generated_at', '')

      @page_width = settings.fetch('page_width', 0).to_l
      @page_height = settings.fetch('page_height', 0).to_l
      @page_header = settings.fetch('page_header', false)
      @parts_colored = settings.fetch('parts_colored', false)
      @parts_opacity = settings.fetch('parts_opacity', 1)
      @pins_hidden = settings.fetch('pins_hidden', false)
      @pins_text = settings.fetch('pins_text', 0)
      @camera_view = Geom::Vector3d.new(settings.fetch('camera_view', nil))
      @camera_zoom = settings.fetch('camera_zoom', 1)
      @camera_target = Geom::Point3d.new(settings.fetch('camera_target', nil))
      @exploded_model_radius =settings.fetch('exploded_model_radius', 1)

      @cutlist = cutlist

    end

    # -----

    def run
      return { :errors => [ [ 'core.error.feature_unavailable', { :version => 2018 } ] ] } if Sketchup.version_number < 1800000000
      return { :errors => [ 'default.error' ] } unless @cutlist
      return { :errors => [ 'tab.cutlist.error.obsolete_cutlist' ] } if @cutlist.obsolete?

      model = Sketchup.active_model
      return { :errors => [ 'tab.cutlist.error.no_model' ] } unless model

      return { :errors => [ 'tab.cutlist.layout.error.no_part' ] } if @parts_infos.empty?

      # Retrieve target group
      target_group = @cutlist.get_group(@target_group_id)

      # Base document name
      doc_name = "#{@cutlist.model_name.empty? ? File.basename(@cutlist.filename, '.skp') : @cutlist.model_name}#{@cutlist.page_name.empty? ? '' : " - #{@cutlist.page_name}"}#{target_group && target_group.material_type != MaterialAttributes::TYPE_UNKNOWN ? " - #{target_group.material_name} #{target_group.std_dimension}" : ''}"

      # Ask for layout file path
      layout_path = UI.savepanel(Plugin.instance.get_i18n_string('tab.cutlist.export.title'), @cutlist.dir, _sanitize_filename("#{doc_name}.layout"))
      if layout_path

        # Start model modification operation
        model.start_operation('OpenCutList - Export to Layout', true, false, true)

        # CREATE SKP FILE

        uuid = SecureRandom.uuid

        skp_dir = File.join(Plugin.instance.temp_dir, 'skp')
        unless Dir.exist?(skp_dir)
          Dir.mkdir(skp_dir)
        end
        skp_path = File.join(skp_dir, "#{uuid}.skp")

        materials = model.materials
        definitions = model.definitions
        styles = model.styles

        tmp_definition = definitions.add(uuid)

        # Iterate on parts
        @parts_infos.each do |part_info|

          # Retrieve part
          part = @cutlist.get_real_parts([ part_info['id'] ]).first

          # Convert three matrix to transformation
          transformation = Geom::Transformation.new(part_info['matrix'])

          # Retrieve part's material and definition
          material = materials[part.material_name]
          definition = definitions[part.definition_id]

          # Draw part in tmp definition
          _draw_part(tmp_definition, part, definition, transformation, @parts_colored && material ? material : nil)

        end

        view = model.active_view
        camera = view.camera
        eye = camera.eye
        target = camera.target
        up = camera.up
        perspective = camera.perspective?

        # Workaround to set camera in Layout file : briefly change current model's camera
        camera.perspective = false
        camera.set(Geom::Point3d.new(
          @camera_view.x * @exploded_model_radius + @camera_target.x,
          @camera_view.y * @exploded_model_radius + @camera_target.y,
          @camera_view.z * @exploded_model_radius + @camera_target.z
        ), @camera_target, @camera_view.parallel?(Z_AXIS) ? Y_AXIS : Z_AXIS)

        # Add style
        selected_style = styles.selected_style
        styles.add_style(File.join(__dir__, '..', '..', '..', 'style', "ocl_layout_#{@parts_colored ? 'colored' : 'monochrome'}_#{@parts_opacity == 1 ? 'opaque' : 'translucent'}.style"), true)

        # Save tmp definition as in skp file
        skp_success = tmp_definition.save_as(skp_path)

        # Restore model's style
        styles.selected_style = selected_style

        # Restore model's camera
        camera.perspective = perspective
        camera.set(eye, target, up)

        # Remove tmp definition
        model.definitions.remove(tmp_definition)

        # Commit model modification operation
        model.commit_operation

        return { :errors => [ 'tab.cutlist.layout.error.failed_to_save_as_skp' ] } unless skp_success

        # CREATE LAYOUT FILE

        doc = Layout::Document.new

        # Set document's page infos
        page_info = doc.page_info
        page_info.width = @page_width
        page_info.height = @page_height
        page_info.top_margin = 0.25
        page_info.right_margin = 0.25
        page_info.bottom_margin = 0.25
        page_info.left_margin = 0.25

        # Set document's units and precision
        case DimensionUtils.instance.length_unit
        when DimensionUtils::INCHES
          if DimensionUtils.instance.length_format == DimensionUtils::FRACTIONAL
            doc.units = Layout::Document::FRACTIONAL_INCHES
          else
            doc.units = Layout::Document::DECIMAL_INCHES
          end
        when DimensionUtils::FEET
          doc.units = Layout::Document::DECIMAL_FEET
        when DimensionUtils::MILLIMETER
          doc.units = Layout::Document::DECIMAL_MILLIMETERS
        when DimensionUtils::CENTIMETER
          doc.units = Layout::Document::DECIMAL_CENTIMETERS
        when DimensionUtils::METER
          doc.units = Layout::Document::DECIMAL_METERS
        end
        doc.precision = _to_layout_length_precision(DimensionUtils.instance.length_precision)

        page = doc.pages.first
        layer = doc.layers.first

        # Set page name
        page.name = doc_name

        # Set auto text definitions
        doc.auto_text_definitions.add('OpenCutListGeneratedAt', Layout::AutoTextDefinition::TYPE_CUSTOM_TEXT).custom_text = @generated_at
        doc.auto_text_definitions.add('OpenCutListLengthUnit', Layout::AutoTextDefinition::TYPE_CUSTOM_TEXT).custom_text = Plugin.instance.get_i18n_string("default.unit_#{DimensionUtils.instance.length_unit}")
        doc.auto_text_definitions.add('OpenCutListScale', Layout::AutoTextDefinition::TYPE_CUSTOM_TEXT).custom_text = _camera_zoom_to_scale(@camera_zoom)

        # Add header
        current_y = page_info.top_margin
        if @page_header

          gutter = 0.1
          font_family = 'Verdana'

          draw_text = _create_formated_text(Plugin.instance.get_i18n_string('tab.cutlist.layout.title'), Geom::Point2d.new(page_info.left_margin, current_y), Layout::FormattedText::ANCHOR_TYPE_TOP_LEFT, { :font_family => font_family, :font_size => 18, :text_alignment => Layout::Style::ALIGN_LEFT })
          doc.add_entity(draw_text, layer, page)

          current_y = draw_text.bounds.lower_right.y

          date_and_unit_text = _create_formated_text('<OpenCutListGeneratedAt>  |  <OpenCutListLengthUnit>  |  <OpenCutListScale>', Geom::Point2d.new(page_info.width - page_info.right_margin, current_y), Layout::FormattedText::ANCHOR_TYPE_BOTTOM_RIGHT, { :font_family => font_family, :font_size => 10, :text_alignment => Layout::Style::ALIGN_RIGHT })
          doc.add_entity(date_and_unit_text, layer, page)

          name_text = _create_formated_text('<PageName>', Geom::Point2d.new(page_info.width / 2, current_y + gutter * 2), Layout::FormattedText::ANCHOR_TYPE_TOP_CENTER, { :font_family => font_family, :font_size => 15, :text_alignment => Layout::Style::ALIGN_CENTER })
          doc.add_entity(name_text, layer, page)
          current_y = name_text.bounds.lower_right.y

          unless @cutlist.model_description.empty?
            model_description_text = _create_formated_text(@cutlist.model_description, Geom::Point2d.new(page_info.width / 2, current_y), Layout::FormattedText::ANCHOR_TYPE_TOP_CENTER, { :font_family => font_family, :font_size => 9, :text_alignment => Layout::Style::ALIGN_CENTER })
            doc.add_entity(model_description_text, layer, page)
            current_y = model_description_text.bounds.lower_right.y
          end

          unless @cutlist.page_description.empty?
            page_description_text = _create_formated_text(@cutlist.page_description, Geom::Point2d.new(page_info.width / 2, current_y), Layout::FormattedText::ANCHOR_TYPE_TOP_CENTER, { :font_family => font_family, :font_size => 9, :text_alignment => Layout::Style::ALIGN_CENTER })
            doc.add_entity(page_description_text, layer, page)
            current_y = page_description_text.bounds.lower_right.y
          end

          rectangle = _create_rectangle(Geom::Point2d.new(page_info.left_margin, draw_text.bounds.lower_right.y + gutter), Geom::Point2d.new(page_info.width - page_info.right_margin, current_y + gutter), { :solid_filled => false })
          doc.add_entity(rectangle, layer, page)
          current_y = rectangle.bounds.lower_right.y + gutter

        end

        # Add SketchUp model entity
        skp = Layout::SketchUpModel.new(skp_path, Geom::Bounds2d.new(
          page_info.left_margin,
          current_y,
          page_info.width - page_info.left_margin - page_info.right_margin,
          page_info.height - current_y - page_info.bottom_margin
        ))
        skp.perspective = false
        skp.render_mode = @parts_colored ?  Layout::SketchUpModel::HYBRID_RENDER : Layout::SketchUpModel::VECTOR_RENDER
        skp.display_background = false
        skp.scale = @camera_zoom
        skp.preserve_scale_on_resize = true
        doc.add_entity(skp, layer, page)

        skp.render

        # Add pins
        unless @pins_hidden

          leader_type =

          @pins_infos.each do |pin_info|
            _add_connected_label(doc, layer, page, skp,
                                 pin_info['text'],
                                 Geom::Point3d.new(pin_info['target']),
                                 Geom::Point3d.new(pin_info['anchor']),
                                 {
                                   :font_size => 7,
                                   :solid_filled => true,
                                   :fill_color => pin_info['background_color'].nil? ? Sketchup::Color.new(0xffffff) : Sketchup::Color.new(pin_info['background_color']),
                                   :text_color => pin_info['color'].nil? ? nil : Sketchup::Color.new(pin_info['color']),
                                   :stroke_width => 0.5
                                 }
            )
          end

        end

        # Save Layout file
        begin
          doc.save(layout_path)
        rescue => e
          return { :errors => [ [ 'tab.cutlist.layout.error.failed_to_layout', { :error => e.message } ] ] }
        ensure
          # Delete Skp file
          File.delete(skp_path)
        end

        return {
          :export_path => layout_path
        }
      end

      {
        :cancelled => true
      }
    end

    # -----

    private

    def _draw_part(tmp_definition, part, definition, transformation = nil, material = nil)

      group = tmp_definition.entities.add_group
      group.transformation = transformation
      case @pins_text
      when 1  # PINS_TEXT_NAME
        group.name = part.name
      when 2  # PINS_TEXT_NUMBER_AND_NAME
        group.name = "#{part.number} - #{part.name}"
      else    # PINS_TEXT_NUMBER
        group.name = part.number
      end
      group.material = material if @parts_colored

      # Redraw the entire part through one PolygonMesh
      part_mesh = Geom::PolygonMesh.new
      painted_faces = {}
      soft_edges_points = []
      _populate_part_mesh_with_entities(part_mesh, painted_faces, soft_edges_points, definition.entities, nil, material)
      group.entities.fill_from_mesh(part_mesh, true, Geom::PolygonMesh::NO_SMOOTH_OR_HIDE)

      # Add painted meshes
      painted_faces.each do |mesh, material|
        group.entities.add_faces_from_mesh(mesh, Geom::PolygonMesh::NO_SMOOTH_OR_HIDE, material)
      end

      # Remove coplanar edges created by fill_from_mesh and add_faces_from_mesh to reduce exported data
      coplanar_edges = []
      group.entities.grep(Sketchup::Edge).each do |edge|
        edge.faces.each_cons(2) { |pair|
          if pair.first.normal.parallel?(pair.last.normal)
            coplanar_edges << edge
            break
          end
        }
      end
      group.entities.erase_entities(coplanar_edges)

      # Add soft edges
      soft_edges_points.each do |edge_points|
        group.entities.add_edges(edge_points).each { |edge| edge.soft = true }
      end

    end

    def _populate_part_mesh_with_entities(part_mesh, painted_meshes, soft_edges_points, entities, transformation = nil, material = nil)

      entities.each do |entity|

        next unless entity.visible? && _layer_visible?(entity.layer)

        if entity.is_a?(Sketchup::Face)

          points_indices = []

          mesh = entity.mesh(7) # POLYGON_MESH_POINTS (0) | POLYGON_MESH_UVQ_FRONT (1) | POLYGON_MESH_UVQ_BACK (3) | POLYGON_MESH_NORMALS (4)
          mesh.transform!(transformation) unless transformation.nil?

          # If face is painted, do not add it to part_mesh
          if @parts_colored && !entity.material.nil? && entity.material != material
            painted_meshes.store(mesh, entity.material)
          else
            mesh.points.each { |point| points_indices << part_mesh.add_point(point) }
            mesh.polygons.each { |polygon| part_mesh.add_polygon(polygon.map { |index| points_indices[index.abs - 1] }) }
          end

          # Extract soft edges to re-add them later
          entity.edges.each { |edge|
            if edge.soft?
              edge_points = edge.vertices.map { |vertex| vertex.position }
              Point3dUtils.transform_points(edge_points, transformation)
              soft_edges_points << edge_points
            end
          }

        elsif entity.is_a?(Sketchup::Group)
          _populate_part_mesh_with_entities(part_mesh, painted_meshes, soft_edges_points, entity.entities, TransformationUtils.multiply(transformation, entity.transformation), material)
        elsif entity.is_a?(Sketchup::ComponentInstance) && entity.definition.behavior.cuts_opening?
          _populate_part_mesh_with_entities(part_mesh, painted_meshes, soft_edges_points, entity.definition.entities, TransformationUtils.multiply(transformation, entity.transformation), material)
        end

      end

    end

    def _sanitize_filename(filename)
      filename
        .gsub(/\//, '∕')
        .gsub(/꞉/, '꞉')
    end

    def _create_formated_text(text, anchor, anchor_type, style = nil)
      entity = Layout::FormattedText.new(text, anchor, anchor_type)
      if style
        entity_style = entity.style(0)
        entity_style.font_size = style[:font_size] unless style[:font_size].nil?
        entity_style.font_family = style[:font_family] unless style[:font_family].nil?
        entity_style.text_bold = style[:text_bold] unless style[:text_bold].nil?
        entity_style.text_alignment = style[:text_alignment] unless style[:text_alignment].nil?
        entity.apply_style(entity_style)
      end
      entity
    end

    def _create_rectangle(upper_left, lower_right, style = nil)
      entity = Layout::Rectangle.new(Geom::Bounds2d.new(upper_left, lower_right))
      if style
        entity_style = entity.style
        entity_style.solid_filled = style[:solid_filled] unless style[:solid_filled].nil?
        entity.style = entity_style
      end
      entity
    end

    def _add_connected_label(doc, layer, page, skp, text, target_3d, anchor_3d, style = nil)
      entity = Layout::Label.new(
        text,
        Layout::Label::LEADER_LINE_TYPE_SINGLE_SEGMENT,
        Geom::Point2d.new,
        skp.model_to_paper_point(anchor_3d),
        Layout::FormattedText::ANCHOR_TYPE_TOP_LEFT
      )
      doc.add_entity(entity, layer, page)
      entity.connect(Layout::ConnectionPoint.new(skp, target_3d))
      if style
        entity_style = entity.style

        text_style = entity_style.get_sub_style(Layout::Style::LABEL_TEXT)
        text_style.font_size = style[:font_size] unless style[:font_size].nil?
        text_style.solid_filled = style[:solid_filled] unless style[:solid_filled].nil?
        text_style.fill_color = style[:fill_color] unless style[:fill_color].nil?
        text_style.text_color = style[:text_color] unless style[:text_color].nil?
        entity_style.set_sub_style(Layout::Style::LABEL_TEXT, text_style)

        leader_line_style = entity_style.get_sub_style(Layout::Style::LABEL_LEADER_LINE)
        leader_line_style.stroke_width = style[:stroke_width] unless style[:stroke_width].nil?
        entity_style.set_sub_style(Layout::Style::LABEL_LEADER_LINE, leader_line_style)

        entity.style = entity_style
      end
      entity
    end

    def _to_layout_length_precision(su_length_precision)
      return 1 if su_length_precision == 0
      "0.#{'1'.ljust(su_length_precision - 1, '0')}".to_f
    end

    def _camera_zoom_to_scale(zoom)
      if zoom > 1
        scale = "#{zoom.round(3)}:1"
      elsif zoom < 1
        scale = "1:#{(1 / zoom).round(3)}"
      else
        scale = '1:1'
      end
      scale
    end

  end

end