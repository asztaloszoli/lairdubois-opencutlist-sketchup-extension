module Ladb::OpenCutList

  class DrawingDef

    attr_reader :bounds, :face_manipulators, :surface_manipulators, :edge_manipulators, :curve_manipulators
    attr_accessor :transformation, :input_normal, :input_face_manipulator, :input_edge_manipulator

    def initialize

      @transformation = Geom::Transformation.new

      @bounds = Geom::BoundingBox.new

      @face_manipulators = []
      @surface_manipulators = []
      @edge_manipulators = []
      @curve_manipulators = []

      @input_normal = Z_AXIS
      @input_face_manipulator = nil
      @input_edge_manipulator = nil

    end

  end

end