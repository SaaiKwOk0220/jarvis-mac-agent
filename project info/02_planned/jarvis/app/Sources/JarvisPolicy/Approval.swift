import JarvisDomain

/// Validates an approval against the request's immutable action digest.
public func validateApproval(request: ToolRequest, approvalDigest: String) -> Bool {
    approvalDigest == request.payloadDigest
}
