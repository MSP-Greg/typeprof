module TypeProf
  module Reporters
    module_function

    def generate_analysis_trace(state, visited, backward_edge)
      return nil if visited[state]
      visited[state] = true
      prev_states = backward_edges[state]
      if prev_states
        prev_states.each_key do |pstate|
          trace = generate_analysis_trace(pstate, visited, backward_edge)
          return [state] + trace if trace
        end
        nil
      else
        []
      end
    end

    def filter_backtrace(trace)
      ntrace = [trace.first]
      trace.each_cons(2) do |ep1, ep2|
        ntrace << ep2 if ep1.ctx != ep2.ctx
      end
      ntrace
    end

    def show_error(errors, backward_edge, output)
      return if errors.empty?
      return unless Config.options[:show_errors]

      output.puts "# Errors"
      errors.each do |ep, msg|
        if ENV["TP_DETAIL"]
          backtrace = filter_backtrace(generate_analysis_trace(ep, {}, backward_edge))
        else
          backtrace = [ep]
        end
        loc, *backtrace = backtrace.map do |ep|
          ep&.source_location
        end
        output.puts "#{ loc }: #{ msg }"
        backtrace.each do |loc|
          output.puts "        from #{ loc }"
        end
      end
      output.puts
    end

    def show_reveal_types(scratch, reveal_types, output)
      return if reveal_types.empty?

      output.puts "# Revealed types"
      reveal_types.each do |source_location, ty|
        output.puts "#  #{ source_location } #=> #{ ty.screen_name(scratch) }"
      end
      output.puts
    end

    def show_gvars(scratch, gvars, output)
      # A signature for global variables is not supported in RBS
      return if gvars.dump.empty?

      output.puts "# Global variables"
      gvars.dump.each do |gvar_name, entry|
        next if entry.type == Type.bot
        s = entry.rbs_declared ? "#" : ""
        output.puts s + "#{ gvar_name } : #{ entry.type.screen_name(scratch) }"
      end
      output.puts
    end
  end

  class RubySignatureExporter
    def initialize(
      scratch,
      class_defs, iseq_method_to_ctxs, sig_fargs, sig_ret, yields
    )
      @scratch = scratch
      @class_defs = class_defs
      @iseq_method_to_ctxs = iseq_method_to_ctxs
      @sig_fargs = sig_fargs
      @sig_ret = sig_ret
      @yields = yields
    end

    def show(stat_eps, output)
      output.puts "# Classes" # and Modules

      stat_classes = {}
      stat_methods = {}
      first = true

      @class_defs.each_value do |class_def|
        included_mods = class_def.modules[false].filter_map do |mod_def, absolute_paths|
          next if absolute_paths.all? {|path| !path || Config.check_dir_filter(path) == :exclude }
          mod_def.name
        end

        extended_mods = class_def.modules[true].filter_map do |mod_def, absolute_paths|
          next if absolute_paths.all? {|path| !path || Config.check_dir_filter(path) == :exclude }
          mod_def.name
        end

        explicit_methods = {}
        iseq_methods = {}
        attr_methods = {}
        ivars = class_def.ivars.dump
        cvars = class_def.cvars.dump
        class_def.methods.each do |(singleton, mid), mdefs|
          mdefs.each do |mdef|
            case mdef
            when ISeqMethodDef
              ctxs = @iseq_method_to_ctxs[mdef]
              next unless ctxs

              ctxs.each do |ctx|
                next if mid != ctx.mid
                next if Config.check_dir_filter(ctx.iseq.absolute_path) == :exclude

                method_name = ctx.mid
                method_name = "self.#{ method_name }" if singleton

                fargs = @sig_fargs[ctx]
                ret_tys = @sig_ret[ctx]

                iseq_methods[method_name] ||= []
                iseq_methods[method_name] << @scratch.show_signature(fargs, @yields[ctx], ret_tys)
              end
            when AttrMethodDef
              next if Config.check_dir_filter(mdef.absolute_path) == :exclude
              mid = mid.to_s[0..-2].to_sym if mid.to_s.end_with?("=")
              method_name = mid
              method_name = "self.#{ mid }" if singleton
              method_name = [method_name, :"@#{ mid }" != mdef.ivar]
              if attr_methods[method_name]
                if attr_methods[method_name][0] != mdef.kind
                  attr_methods[method_name][0] = :accessor
                end
              else
                entry = ivars[[singleton, mdef.ivar]]
                ty = entry ? entry.type : Type.any
                attr_methods[method_name] = [mdef.kind, ty.screen_name(@scratch)]
              end
            when TypedMethodDef
              if mdef.rbs_source
                method_name, sigs = mdef.rbs_source
                explicit_methods[method_name] = sigs
              end
            end
          end
        end

        ivars = ivars.map do |(singleton, var), entry|
          next if entry.absolute_paths.all? {|path| Config.check_dir_filter(path) == :exclude }
          ty = entry.type
          next unless var.to_s.start_with?("@")
          var = "self.#{ var }" if singleton
          next if attr_methods[[singleton ? "self.#{ var.to_s[1..] }" : var.to_s[1..].to_sym, false]]
          [var, ty.screen_name(@scratch), entry.rbs_declared]
        end.compact

        cvars = cvars.map do |var, entry|
          next if entry.absolute_paths.all? {|path| Config.check_dir_filter(path) == :exclude }
          [var, entry.type.screen_name(@scratch), entry.rbs_declared]
        end

        if !class_def.absolute_path || Config.check_dir_filter(class_def.absolute_path) == :exclude
          next if included_mods.empty? && extended_mods.empty? && ivars.empty? && cvars.empty? && iseq_methods.empty? && attr_methods.empty?
        end

        output.puts unless first
        first = false

        if class_def.superclass
          omit = @class_defs[class_def.superclass].klass_obj == Type::Builtin[:obj] || class_def.klass_obj == Type::Builtin[:obj]
          superclass = omit ? "" : " < #{ @class_defs[class_def.superclass].name }"
        end

        output.puts "#{ class_def.kind } #{ class_def.name }#{ superclass }"
        included_mods.sort.each do |ty|
          output.puts "  include #{ ty }"
        end
        extended_mods.sort.each do |ty|
          output.puts "  extend #{ ty }"
        end
        ivars.each do |var, ty, rbs_declared|
          s = rbs_declared ? "# " : "  "
          output.puts s + "#{ var } : #{ ty }" unless var.start_with?("_")
        end
        cvars.each do |var, ty, rbs_declared|
          s = rbs_declared ? "# " : "  "
          output.puts s + "#{ var } : #{ ty }"
        end
        attr_methods.each do |(method_name, hidden), (kind, ty)|
          output.puts "  attr_#{ kind } #{ method_name }#{ hidden ? "()" : "" } : #{ ty }"
        end
        explicit_methods.each do |method_name, sigs|
          sigs = sigs.sort.join("\n" + "#" + " " * (method_name.size + 6) + "| ")
          output.puts "# def #{ method_name } : #{ sigs }"
        end
        iseq_methods.each do |method_name, sigs|
          sigs = sigs.sort.join("\n" + " " * (method_name.size + 7) + "| ")
          output.puts "  def #{ method_name } : #{ sigs }"
        end
        output.puts "end"
      end

      if ENV["TP_STAT"]
        output.puts "statistics:"
        output.puts "  %d execution points" % stat_eps.size
        output.puts "  %d classes" % stat_classes.size
        output.puts "  %d methods (in total)" % stat_methods.size
      end
      if ENV["TP_COVERAGE"]
        coverage = {}
        stat_eps.each do |ep|
          path = ep.ctx.iseq.path
          lineno = ep.ctx.iseq.linenos[ep.pc] - 1
          (coverage[path] ||= [])[lineno] ||= 0
          (coverage[path] ||= [])[lineno] += 1
        end
        File.binwrite("coverage.dump", Marshal.dump(coverage))
      end
    end
  end
end
