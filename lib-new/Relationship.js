// Generated by CoffeeScript 1.7.1
(function() {
  var Relationship, utils;

  utils = require('./utils');

  module.exports = Relationship = (function() {
    function Relationship(opts) {
      if (opts == null) {
        opts = {};
      }
      this._id = opts._id, this.type = opts.type, this.properties = opts.properties, this._fromId = opts._fromId, this._toId = opts._toId;
    }

    Relationship.prototype.equals = function(other) {
      return (other instanceof Relationship) && (this._id === other._id);
    };

    Relationship.prototype.toString = function() {
      return "-[" + this._id + ":" + this.type + "]-";
    };

    Relationship._fromRaw = function(obj) {
      var data, end, fromId, id, self, start, toId, type;
      if ((!obj) || (typeof obj !== 'object')) {
        return null;
      }
      data = obj.data, self = obj.self, type = obj.type, start = obj.start, end = obj.end;
      if ((!self) || (typeof self !== 'string') || (!type) || (typeof type !== 'string') || (!start) || (typeof start !== 'string') || (!end) || (typeof end !== 'string') || (!data) || (typeof data !== 'object')) {
        return null;
      }
      id = utils.parseId(self);
      fromId = utils.parseId(start);
      toId = utils.parseId(end);
      return new Relationship({
        _id: id,
        type: type,
        properties: data,
        _fromId: fromId,
        _toId: toId
      });
    };

    return Relationship;

  })();

}).call(this);

//# sourceMappingURL=Relationship.map
