library autonotify.support;

import "package:polymer/polymer.dart";
import "package:observe/observe.dart";
import "package:smoke/smoke.dart";
import "package:logging/logging.dart";
import "dart:async";
import "dart:js";
Logger _logger = new Logger("autonotify.support");

abstract class PropertyNotifier {
  static final Map _notifiersCache = {};
  static final Map _cycleDetection={};



  bool notifyPath(String name,var newValue);
  notifySplice(List array, String path, int index, int added, List removed);

  PropertyNotifier() {

  }

  factory PropertyNotifier.from(target) {
    if (_cycleDetection[target]) {
      _logger.warning("A cycle in notifiers as been detected : ${target}");
      return null;
    }
    _cycleDetection[target] = true;
    PropertyNotifier n = _notifiersCache.putIfAbsent(target,() {
        if (target is PolymerElement) {
          return new PolymerElementPropertyNotifier(target);
        }  else if (target is List || target is ObservableList) {
          return new ListPropertyNotifier(target);
        } else if (target is Observable) {
          return new ObservablePropertyNotifier(target);
        } else {
          return null;
        }
    });

    if (n==null) {
      _notifiersCache.remove(target);
    }

    _cycleDetection[target]=false;

    return n;
  }

  void destroy();

  static PropertyNotifier evict(target) => _notifiersCache.remove(target);
}

abstract class HasChildrenMixin implements PropertyNotifier {
  Map<String,HasParentMixin> subNodes = {};

  void addChildren(target) {
    Map children = discoverChildren(target);
    children.forEach((String name,subTarget) {
      HasParentMixin prev = subNodes.remove(name);
      if (prev!=null) {
        prev.removeReference(name,this);
      }


      HasParentMixin child = new PropertyNotifier.from(subTarget);
      if (child!=null) {
        subNodes[subTarget] = child
          ..addReference(name, this);
      }

    });
  }



  Map discoverChildren(target);


  void destroyChildren() {
    subNodes.forEach((String name,HasParentMixin child){
      child.removeReference(name,this);
    });
    subNodes.clear();
  }

}

abstract class HasParentMixin implements PropertyNotifier {
  Map<String,List<HasChildrenMixin>> parents={};

  void removeReference(String name,HasChildrenMixin parent) {
    List<HasChildrenMixin> refs = parents[name];
    if (refs!=null) {
      refs.remove(parent);
      if (refs.length==0) {
        refs.remove(name);
      }
    }
    if (parents.isEmpty) {
      // no reason to exist if no one references me
      destroy();
    }
  }

  void addReference(String name, HasChildrenMixin parent) {
    List<HasChildrenMixin> refs = parents.putIfAbsent(name,() => new List());
    refs.add(parent);
  }

  void renameReference(String fromName,String toName, HasChildrenMixin parent) {
    List<HasChildrenMixin> refs = parents[fromName];
    if (refs!=null) {
      refs.remove(parent);
      if (refs.length==0) {
        refs.remove(fromName);
      }
    }
    refs = parents.putIfAbsent(toName,ifAbsent:() => new List());
    refs.add(parent);

  }

  bool notifyPath(String name, newValue) {
    parents.forEach((String parentName,List<PropertyNotifier> parents1) {
      parents1.forEach((PropertyNotifier parent) {
        parent.notifyPath(parentName+"."+name,newValue);
      });
    });
  }

  notifySplice(List array, String path, int index, int added, List removed) {
    parents.forEach((String parentName,List<PropertyNotifier> parents1) {
      parents1.forEach((PropertyNotifier parent) {
        parent.notifySplice(array,path!=null? parentName+"."+path: parentName,index,added,removed);
      });
    });
  }
}

abstract class HasChildrenReflectiveMixin implements HasChildrenMixin {

  Map discoverChildren(target) {
    List<Declaration> fields = query(target.runtimeType,new QueryOptions(includeFields:true,includeProperties:true,includeInherited:false,withAnnotations:[ObservableProperty]));
    return new Map.fromIterable(fields,
      key:(Declaration f) => symbolToName(f.name),
      value:(Declaration f) => read(target,f.name));
  }

  StreamSubscription _sub;

  init(Observable _target) {
    addChildren(_target);
    _sub=observe(_target);
  }

  StreamSubscription observe(Observable target) {
    // Attach listener too
    return target.changes.listen((List<ChangeRecord> recs) {
      recs.where((ChangeRecord cr) => cr is PropertyChangeRecord).forEach((PropertyChangeRecord pcr) {
        String name = symbolToName(pcr.name);
        var val = pcr.newValue;
        notifyPath(name,val);

        // Replace observer
        HasParentMixin child = subNodes.remove(name);
        if (child!=null) {
          child.removeReference(name,this);
        }

        child = new PropertyNotifier.from(val);
        if (child!=null) {
          subNodes[name] = child
            ..addReference(name,this);
        }

      });
    });
  }

  void cleanUpListener() {
    _sub.cancel();

  }


}

class PolymerElementPropertyNotifier extends PropertyNotifier with HasChildrenMixin, HasChildrenReflectiveMixin {
  PolymerElement _element;

  PolymerElementPropertyNotifier(PolymerElement element) {
    _element = element;
    if (!(element is Observable)) {
      throw "Using notifier on non observable Polymer";
    }
    init(_element);
  }

  bool notifyPath(String name, newValue) {
    if (_logger.isLoggable(Level.FINE)) {
      _logger.fine("${_element} NOTIFY ${name} with ${newValue}");
    }
    return _element.notifyPath(name, newValue);
  }

  notifySplice(List array, String path, int index, int added, List removed) {
    if (_logger.isLoggable(Level.FINE)) {
      _logger.fine("${_element} NOTIFY SPLICE OF ${path} at ${index}, added ${added} , removed ${removed.length}");
    }
/*
    if (removed!=null&&removed.length>0) {
      _element.removeRange(path,index,removed.length);
    }

    if (added>0) {
      _element.insertAll(path,index,array.sublist(index,added));
    }
*/
    //if (jsValue(array).length!=array.length) {
    //_tmpFakeNoLoop[array]=true;
    //  _element.jsElement.callMethod("splice",[path,index,removed.length]..addAll(array.sublist(index,added).map((x)=>jsValue(x))));
    //} else {
      JsArray ar = jsValue(array);
    ar.callMethod("splice",[index, removed.length]..addAll(array.sublist(index,index+added).map((x)=>jsValue(x))));
      _element.jsElement.callMethod('_notifySplice', [ar, path, index, added, jsValue(removed)]);
    //}

   // _element.jsElement.callMethod("splice",[path,index,removed.length]..addAll(array.sublist(index,added).map((x)=>jsValue(x))));

  //  var ar = _element.jsElement[path];
    //  return
  }

  void destroy() {
    cleanUpListener();
    destroyChildren();
    PropertyNotifier.evict(_element);
  }


}

Map<List,bool> _tmpFakeNoLoop = new Map();

class ObservablePropertyNotifier extends PropertyNotifier with HasParentMixin, HasChildrenMixin,HasChildrenReflectiveMixin {

  Observable _target;

  ObservablePropertyNotifier(Observable target) {
    _target = target;
    init(_target);
  }

  void destroy() {
    cleanUpListener();
    destroyChildren();
    PropertyNotifier.evict(_target);
  }


}

class ListPropertyNotifier extends PropertyNotifier with HasParentMixin,HasChildrenMixin {

  List _target;
  StreamSubscription _sub;

  ListPropertyNotifier(List target) {
    _target = target;
    addChildren(_target);

    if (_target is ObservableList) {
      // Observe changes on list too
      _sub = (target as ObservableList).listChanges.listen((List<ListChangeRecord> rc) {
        // Notify splice
        rc.forEach((ListChangeRecord lc) {
          // Avoid loops when splicing jsArray
          if (_tmpFakeNoLoop[_target]) {
            _tmpFakeNoLoop.remove(_target);
           return;
          }
          notifySplice(_target, null, lc.index, lc.addedCount, lc.removed);

          // Adjust references

          // Fix observers
          if(lc.removed!=null&&lc.removed.length>0) {
            for(int i=0;i<lc.removed.length;i++) {
              String name = (lc.index+i).toString();
              subNodes.remove(name).removeReference(name,this);
            }

            // fix path on the rest
            for (int i=lc.index;i<target.length;i++) {
              String fromName = (i+lc.removed.length).toString();
              String toName = i.toString();

              subNodes[toName]=subNodes.remove(fromName)
                ..renameReference(int.parse(fromName),int.parse(toName),this);

            }

          }
          if (lc.addedCount>0) {
            // Fix path on tail
            for (int i=lc.index+lc.addedCount;i<target.length;i++) {
              String fromName = (i-lc.addedCount).toString();
              String toName = i.toString();

              subNodes[toName] =subNodes.remove(fromName)
                ..renameReference(int.parse(fromName),int.parse(toName),this);
            }

            // Add new observers
            for (int i=lc.index;i<lc.addedCount+lc.index;i++) {
              if (target[i] is Observable || target[i] is ObservableList) {
                HasParentMixin child = new PropertyNotifier.from(target[i]);
                if (child!=null) {
                  subNodes[i.toString()] = child
                    ..addReference(i.toString(),this);
                }
              }
            }
          }
        });
      });
    }

  }

  Map discoverChildren(_target) {
    return new Map.fromIterable(new List.generate(_target.length,(int index) => index),
      key:(int index) => index.toString(),
      value: (int index) => _target[index]);
  }

  void destroy() {
    if (_sub!=null) {
      _sub.cancel();
    }
    destroyChildren();
    PropertyNotifier.evict(_element);

  }


}

@behavior
abstract class PolymerAutoNotifySupportMixin  {
  PolymerElementPropertyNotifier _rootNotifier;

  static void created(mixin) {
    mixin._rootNotifier = new PropertyNotifier.from(mixin);
  }

  static void detached(mixin) {
    mixin._rootNotifier.destroy();
  }

}