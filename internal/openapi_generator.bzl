# Copyright 2019 OpenAPI-Generator-Bazel Contributors

load("@rules_jvm_external//:defs.bzl", "maven_install")
load("@maven//:compat.bzl", "compat_repositories")

def _comma_separated_pairs(pairs):
    return ",".join([
        "{}={}".format(k, v)
        for k, v in pairs.items()
    ])

def _new_jar_command(ctx, gen_dir):
    jar_cmd = "{jar} cMf {target} -C {srcs} .".format(
            jar = "%s/bin/jar" % ctx.attr._jdk[java_common.JavaRuntimeInfo].java_home,
            target = ctx.outputs.codegen.path,
            srcs = gen_dir,
        )

    # fixme: by default, openapi-generator is rather verbose. this helps with that but can also mask useful error messages
    # when it fails. look into log configuration options. it's a java app so perhaps just a log4j.properties or something
    jar_cmd += " 1>/dev/null"
    return jar_cmd

def _new_generator_command(ctx, declared_dir, rjars):
    java_path = ctx.attr._jdk[java_common.JavaRuntimeInfo].java_executable_exec_path
    gen_cmd = str(java_path)

    jar_delimiter = ":"
    if ctx.attr.is_windows:
        jar_delimiter = ";"

    jars = [ctx.file.openapi_generator_cli] + rjars.to_list()

    gen_cmd += " -cp \"{jars}\" org.openapitools.codegen.OpenAPIGenerator generate -i {spec} -g {generator} -o {output}".format(
        java = java_path,
        jars = jar_delimiter.join([j.path for j in jars]),
        spec = ctx.file.spec.path,
        generator = ctx.attr.generator,
        output = declared_dir.path,
    )

    gen_cmd += ' -p "{properties}"'.format(
        properties = _comma_separated_pairs(ctx.attr.system_properties),
    )

    additional_properties = dict(ctx.attr.additional_properties)

    # This is needed to ensure reproducible Java output
    if ctx.attr.generator == "java" and \
       "hideGenerationTimestamp" not in ctx.attr.additional_properties:
        additional_properties["hideGenerationTimestamp"] = "true"

    gen_cmd += ' --additional-properties "{properties}"'.format(
        properties = _comma_separated_pairs(additional_properties),
    )

    gen_cmd += ' --type-mappings "{mappings}"'.format(
        mappings = _comma_separated_pairs(ctx.attr.type_mappings),
    )

    if ctx.attr.api_package:
        gen_cmd += " --api-package {package}".format(
            package = ctx.attr.api_package,
        )
    if ctx.attr.invoker_package:
        gen_cmd += " --invoker-package {package}".format(
            package = ctx.attr.invoker_package,
        )
    if ctx.attr.model_package:
        gen_cmd += " --model-package {package}".format(
            package = ctx.attr.model_package,
        )
    if ctx.attr.engine:
        gen_cmd += " --engine {package}".format(
            package = ctx.attr.engine,
        )

    # ajc Don't add here, add it in jar command above
    # fixme: by default, openapi-generator is rather verbose. this helps with that but can also mask useful error messages
    # when it fails. look into log configuration options. it's a java app so perhaps just a log4j.properties or something
    #gen_cmd += " 1>/dev/null"
    return gen_cmd

def _impl(ctx):
    jars = _collect_jars(ctx.attr.deps)
    (cjars, rjars) = (jars.compiletime, jars.runtime)

    declared_dir = ctx.actions.declare_directory("%s" % (ctx.attr.name))

    inputs = [
        ctx.file.openapi_generator_cli,
        ctx.file.spec,
    ] + cjars.to_list() + rjars.to_list()

    # TODO: Convert to run
    ctx.actions.run_shell(
        inputs = inputs,
        command = "mkdir -p {gen_dir} && {generator_command} && {jar_command}".format(
            gen_dir = declared_dir.path,
            generator_command = _new_generator_command(ctx, declared_dir, rjars),
            jar_command = _new_jar_command(ctx, declared_dir.path),
        ),
        outputs = [ctx.actions.declare_directory("%s" % (ctx.attr.name)), ctx.outputs.codegen],
        tools = ctx.files._jdk,
    )

    srcs = declared_dir.path

    return struct(
        codegen = ctx.outputs.codegen,
    )

# taken from rules_scala
def _collect_jars(targets):
    """Compute the runtime and compile-time dependencies from the given targets"""  # noqa
    compile_jars = depset()
    runtime_jars = depset()
    for target in targets:
        found = False
        if hasattr(target, "scala"):
            if hasattr(target.scala.outputs, "ijar"):
                compile_jars = depset(transitive = [compile_jars, [target.scala.outputs.ijar]])
            compile_jars = depset(transitive = [compile_jars, target.scala.transitive_compile_exports])
            runtime_jars = depset(transitive = [runtime_jars, target.scala.transitive_runtime_deps])
            runtime_jars = depset(transitive = [runtime_jars, target.scala.transitive_runtime_exports])
            found = True
        if hasattr(target, "JavaInfo"):
            # see JavaSkylarkApiProvider.java,
            # this is just the compile-time deps
            # this should be improved in bazel 0.1.5 to get outputs.ijar
            # compile_jars = depset(transitive = [compile_jars, [target.java.outputs.ijar]])
            compile_jars = depset(transitive = [compile_jars, target[JavaInfo].transitive_deps])
            runtime_jars = depset(transitive = [runtime_jars, target[JavaInfo].transitive_runtime_deps])
            found = True
        if not found:
            # support http_file pointed at a jar. http_jar uses ijar,
            # which breaks scala macros
            runtime_jars = depset(transitive = [runtime_jars, target.files])
            compile_jars = depset(transitive = [compile_jars, target.files])

    return struct(compiletime = compile_jars, runtime = runtime_jars)

_openapi_generator = rule(
    attrs = {
        # downstream dependencies
        "deps": attr.label_list(),
        # openapi spec file
        "spec": attr.label(
            mandatory = True,
            allow_single_file = [
                ".json",
                ".yaml",
            ],
        ),
        "generator": attr.string(mandatory = True),
        "api_package": attr.string(),
        "invoker_package": attr.string(),
        "model_package": attr.string(),
        "additional_properties": attr.string_dict(),
        "system_properties": attr.string_dict(),
        "engine": attr.string(),
        "type_mappings": attr.string_dict(),
        "is_windows": attr.bool(mandatory = True),
        "_jdk": attr.label(
            default = Label("@bazel_tools//tools/jdk:current_java_runtime"),
            providers = [java_common.JavaRuntimeInfo],
        ),
        "maven_space": attr.string(mandatory = True),
        "openapi_generator_cli": attr.label(
            cfg = "host",
            default = Label("@{space}//:org_openapitools_openapi_generator_cli".format(
                              space = ctx.attr.maven_space)),
            allow_single_file = True,
        ),
    },
    outputs = {
        "codegen": "%{name}_codegen.srcjar",
    },
    implementation = _impl,
)

def openapi_generator(name, **kwargs):
    _openapi_generator(
        name = name,
        is_windows = select({
            "@bazel_tools//src/conditions:windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
