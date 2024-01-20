module Ladb::OpenCutList

  require_relative '../../lib/clippy/clippy'
  require_relative '../../model/drawing/drawing_def'
  require_relative '../../model/drawing/drawing_projection_def'

  class CommonDrawingProjectionWorker

    MINIMAL_PATH_AREA = 1e-6

    def initialize(drawing_def, settings = {})

      @drawing_def = drawing_def

      @merge_holes = settings.fetch('merge_holes', false)  # Holes are moved to "hole" layer and all down layers holes are merged to their upper layer

    end

    # -----

    def run
      return { :errors => [ 'default.error' ] } unless @drawing_def.is_a?(DrawingDef)

      bounds_depth = @drawing_def.bounds.depth
      bounds_max = @drawing_def.bounds.max

      depth_min = 0.0
      depth_max = bounds_depth

      z_max = bounds_max.z

      upper_layer_def = PathsLayerDef.new(depth_min, [], DrawingProjectionLayerDef::TYPE_UPPER)

      plds = {}   # plds = Path Layer DefS
      plds[depth_min] = upper_layer_def

      @drawing_def.face_manipulators.each do |face_manipulator|

        # Filter only exposed faces
        next unless !face_manipulator.perpendicular?(Z_AXIS) && face_manipulator.angle_between(@drawing_def.input_normal) < Math::PI / 2.0

        if face_manipulator.surface_manipulator
          f_depth = (z_max - face_manipulator.surface_manipulator.z_max) # Faces sharing the same "surface" are considered as a unique "box"
        else
          f_depth = (z_max - face_manipulator.z_max)
        end
        f_paths = face_manipulator.loop_manipulators.map { |loop_manipulator| loop_manipulator.points }.map { |points| Clippy.points_to_rpath(points) }

        pld = plds[f_depth.round(3)]
        if pld.nil?
          pld = PathsLayerDef.new(f_depth, f_paths, DrawingProjectionLayerDef::TYPE_DEFAULT)
          plds[f_depth.round(3)] = pld
        else
          pld.paths.concat(f_paths) # Just concat, union will be call later in one unique call
        end

      end

      # Sort on depth ASC
      splds = plds.values.sort_by { |layer_def| layer_def.depth }

      # Union paths on each layer
      splds.each do |layer_def|
        next if layer_def.paths.one?
        layer_def.paths = Clippy.execute_union(layer_def.paths)
      end

      # Up to Down difference
      splds.each_with_index do |layer_def, index|
        next if layer_def.paths.empty?
        splds[(index + 1)..-1].each do |lower_layer_def|
          next if lower_layer_def.nil? || lower_layer_def.paths.empty?
          lower_layer_def.paths = Clippy.execute_difference(lower_layer_def.paths, layer_def.paths)
        end
      end

      if @merge_holes

        # Copy upper paths
        upper_paths = upper_layer_def.paths

        # Union upper paths with lower paths
        merged_paths = Clippy.execute_union(upper_paths + splds[1..-1].map { |layer_def| layer_def.paths }.flatten(1).compact)
        merged_polytree = Clippy.execute_polytree(merged_paths)

        # Extract outer paths (first children of pathtree)
        outer_paths = merged_polytree.children.map { |polypath| polypath.path }

        # Extract holes paths and reverse them to plain paths
        through_paths = Clippy.reverse_rpaths(Clippy.delete_rpaths_in(merged_paths, outer_paths))

        # Append "holes" layer def
        splds << PathsLayerDef.new(depth_max, through_paths, DrawingProjectionLayerDef::TYPE_HOLES)

        # Difference with outer and upper to extract holes to propagate
        mask_paths = Clippy.execute_difference(outer_paths, upper_paths)
        mask_polytree = Clippy.execute_polytree(mask_paths)
        mask_polyshapes = Clippy.polytree_to_polyshapes(mask_polytree)

        # Propagate down to up
        pldsr = splds.reverse[0..-2] # Exclude top layer
        mask_polyshapes.each do |mask_polyshape|
          lower_paths = []
          pldsr.each do |layer_def|
            next if layer_def.paths.empty?
            next if Clippy.execute_intersection(layer_def.paths, mask_polyshape.paths).empty?
            layer_def.paths = Clippy.execute_union(lower_paths + layer_def.paths) unless lower_paths.empty?
            lower_paths = Clippy.execute_intersection(layer_def.paths, mask_polyshape.paths)
          end
        end

        # Changed upper layer to "outer"
        upper_layer_def.type = DrawingProjectionLayerDef::TYPE_OUTER
        upper_layer_def.paths = outer_paths

      end

      # Output

      projection_def = DrawingProjectionDef.new(bounds_depth)

      @drawing_def.edge_manipulators.each do |edge_manipulator|
        projection_def.layer_defs << DrawingProjectionLayerDef.new(0, DrawingProjectionLayerDef::TYPE_PATH, [ DrawingProjectionPolylineDef.new(edge_manipulator.points.map { |point| Geom::Point3d.new(point.x, point.y, z_max) }) ])
      end

      @drawing_def.curve_manipulators.each do |curve_manipulator|
        if curve_manipulator.closed?
          poly_def = DrawingProjectionPolygonDef.new(curve_manipulator.points.map { |point| Geom::Point3d.new(point.x, point.y, z_max) }, true)
        else
          poly_def = DrawingProjectionPolylineDef.new(curve_manipulator.points.map { |point| Geom::Point3d.new(point.x, point.y, z_max) })
        end
        projection_def.layer_defs << DrawingProjectionLayerDef.new(0, DrawingProjectionLayerDef::TYPE_PATH, [ poly_def ])
      end

      splds.each do |paths_layer_def|
        next if paths_layer_def.paths.empty?

        polygons = paths_layer_def.paths.map { |path|
          next if Clippy.get_rpath_area(path).abs < MINIMAL_PATH_AREA # Ignore "artifact" paths generated by successive transformation / union / differences
          DrawingProjectionPolygonDef.new(Clippy.rpath_to_points(path, z_max - paths_layer_def.depth), Clippy.is_rpath_positive?(path))
        }.compact

        projection_def.layer_defs << DrawingProjectionLayerDef.new(paths_layer_def.depth, paths_layer_def.type, polygons) unless polygons.empty?

      end

      projection_def
    end

    # -----

    PathsLayerDef = Struct.new(:depth, :paths, :type)

  end

end