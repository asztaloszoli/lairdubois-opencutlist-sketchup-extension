module Ladb::OpenCutList

  require_relative 'common_decompose_drawing_worker'
  require_relative '../../lib/clippy/clippy'
  require_relative '../../lib/geometrix/geometrix'

  class CommonProjectionWorker

    LAYER_POSITION_TOP = 0
    LAYER_POSITION_INSIDE = 1
    LAYER_POSITION_BOTTOM = 2

    def initialize(drawing_def, settings = {})

      @drawing_def = drawing_def

      @option_down_to_up_union = settings.fetch('down_to_up_union', false)
      @option_passthrough_holes = settings.fetch('passthrough_holes', false)

    end

    # -----

    def run
      return { :errors => [ 'default.error' ] } unless @drawing_def.is_a?(DrawingDef)

      bounds_depth = @drawing_def.bounds.depth
      bounds_max = @drawing_def.bounds.max

      z_min = 0.0
      z_max = bounds_max.z

      # Filter only exposed faces
      exposed_face_manipulators = @drawing_def.face_manipulators.select do |face_manipulator|
        !face_manipulator.perpendicular?(@drawing_def.input_face_manipulator) && @drawing_def.input_face_manipulator.angle_between(face_manipulator) < Math::PI / 2.0
      end

      # Populate face def (loops and depth)
      face_defs = []
      exposed_face_manipulators.each do |face_manipulator|

        if face_manipulator.parallel?(@drawing_def.input_face_manipulator) && bounds_depth > 0
          depth = bounds_max.distance_to_plane(face_manipulator.plane).round(6)
        else
          if face_manipulator.surface_manipulator
            depth = (z_max - face_manipulator.surface_manipulator.z_max).round(6)
          else
            depth = (z_max - face_manipulator.z_max).round(6)
          end
        end

        face_def = {
          :depth => depth,
          :loops => face_manipulator.loop_manipulators.map { |loop_manipulator| loop_manipulator.points }
        }
        face_defs << face_def

      end

      top_layer_def = {
        :position => LAYER_POSITION_TOP,
        :depth => z_min,
        :paths => []
      }
      bottom_layer_def = {
        :position => LAYER_POSITION_BOTTOM,
        :depth => z_max,
        :paths => []
      }

      layer_defs = {}
      layer_defs[z_min] = top_layer_def
      layer_defs[z_max] = bottom_layer_def

      face_defs.each do |face_def|

        f_paths = face_def[:loops].map { |points| Clippy.points_to_path(points) }

        layer_def = layer_defs[face_def[:depth]]
        if layer_def.nil?
          layer_def = {
            :position => LAYER_POSITION_INSIDE,
            :depth => face_def[:depth],
            :paths => f_paths
          }
          layer_defs[face_def[:depth]] = layer_def
        else
          layer_def[:paths] = Clippy.union(layer_def[:paths], f_paths)
        end

      end

      # Sort on depth ASC
      ld = layer_defs.values.sort_by { |layer_def| layer_def[:depth] }

      # Up to Down difference
      ld.each_with_index do |layer_def, index|
        next if layer_def[:paths].empty?
        ld[(index + 1)..-1].each do |lower_layer_def|
          next if lower_layer_def[:paths].empty?
          lower_layer_def[:paths] = Clippy.difference(lower_layer_def[:paths], layer_def[:paths])
        end
      end

      if @option_down_to_up_union

        # Down to Up union
        ld.each_with_index do |layer_def, index|
          next if layer_def[:paths].empty?
          ld[(index + 1)..-1].reverse.each do |lower_layer_def|
            next if lower_layer_def[:paths].empty?
            ld[index][:paths] = Clippy.union(ld[index][:paths], lower_layer_def[:paths])
          end
        end

      end

      if @option_passthrough_holes

        # Add top holes as bottom plain
        top_layer_def[:paths].each do |path|
          unless Clippy.ccw_path?(path)
            bottom_layer_def[:paths] << path
          end
        end
        unless bottom_layer_def[:paths].empty?

          # Down to Up union
          ld.each_with_index do |layer_def, index|
            next if layer_def[:paths].empty?
            ld[(index + 1)..-1].reverse.each do |lower_layer_def|
              next if lower_layer_def[:paths].empty?
              ld[index][:paths] = Clippy.union(ld[index][:paths], lower_layer_def[:paths])
            end
          end

        end

      end

      if @option_down_to_up_union

        # Cleanup
        ld.reverse.each_cons(2) do |layer_def_a, layer_def_b|
          layer_def_b[:paths].delete_if { |path| layer_def_a[:paths].include?(path) }
        end

      end

      # Output

      projection_def = ProjectionDef.new

      ld.each do |layer_def|
        next if layer_def[:paths].empty?

        projection_layer_def = ProjectionLayerDef.new(
          layer_def[:position],
          layer_def[:depth],
          layer_def[:paths].map { |path| ProjectionPolygonDef.new(Clippy.path_to_points(path, z_max - layer_def[:depth])) }
        )
        projection_def.layer_defs << projection_layer_def

      end

      projection_def
    end

  end

  # -----

  class ProjectionDef

    attr_reader :layer_defs

    def initialize
      @layer_defs = []
    end

  end

  class ProjectionLayerDef

    attr_reader :depth, :position, :polygon_defs

    def initialize(position, depth, polygon_defs)
      @position = position
      @depth = depth
      @polygon_defs = polygon_defs
    end

  end

  class ProjectionPolygonDef

    attr_reader :points

    def initialize(points)
      @points = points
    end

    def outer?
      if @is_outer.nil?
        @is_outer = Clippy.ccw_points?(@points)
      end
      @is_outer
    end

    def segments
      (@points + [ @points.first ]).each_cons(2).to_a.flatten
    end

    def loop_def
      if @loop_def.nil?
        @loop_def = Geometrix::LoopFinder.find_loop_def(points)
      end
      @loop_def
    end

  end

end