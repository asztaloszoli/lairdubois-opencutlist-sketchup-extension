module Ladb::OpenCutList::Kuix

  class Line < Lines3d

    def initialize(id = nil)
      super([

        [ 0, 0, 0 ],
        [ 1, 1, 1 ]

      ], false, id)
    end

  end

end